import HailAgentRuntime
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The reference ``ContextCompactor``: triggers at a fraction of the model's
/// context window, folds the oldest messages into the rolling summary, and
/// keeps the most recent ones verbatim.
///
/// Boundary rules:
/// - the newest `keepRecent` messages are preferred verbatim, but the
///   preference can be relaxed when that suffix cannot fit;
/// - a cut never splits a ``ChatMessage/toolCall`` from its
///   ``ChatMessage/toolResult``(s): a trailing tool call in the archived
///   prefix backs the cut off until the prefix ends cleanly;
/// - the existing ``PromptContext/contextSummary`` is folded into the new
///   summary by the summarize closure, so the window carries at most one.
public struct SlidingWindowCompactor: ContextCompactor {
    public var estimator: TokenEstimator
    /// Fraction of the window at which compaction triggers.
    public var threshold: Double
    /// Minimum number of semantic messages kept verbatim at the tail. The
    /// actual retained suffix is selected by token cost first.
    public var keepRecent: Int
    /// Space reserved for the next model response.
    public var outputReserve: Int
    /// Space reserved for a possible tool result in the next round.
    public var toolResultReserve: Int

    public init(
        estimator: TokenEstimator = .init(),
        threshold: Double = 0.7,
        keepRecent: Int = 10,
        outputReserve: Int = 512,
        toolResultReserve: Int = 512
    ) {
        self.estimator = estimator
        self.threshold = threshold
        self.keepRecent = keepRecent
        self.outputReserve = max(0, outputReserve)
        self.toolResultReserve = max(0, toolResultReserve)
    }

    public func compact(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measurement: RequestMeasurement? = nil,
        measure: RequestMeasurer? = nil,
        assemble: PromptAssembler = assembleStandardPrompt,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String,
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision {
        let window = budget.contextWindow
        let thresholdTrigger = Int(Double(window) * threshold)

        let requestMeasurement: RequestMeasurement
        if let measurement {
            requestMeasurement = measurement
        } else {
            requestMeasurement = RequestMeasurement(
                tokenCount: try await estimator.estimate(
                    messages: request.messages,
                    tools: request.tools
                ),
                source: .estimated
            )
        }
        let used = requestMeasurement.tokenCount
        guard trigger == .contextLengthExceeded || used >= thresholdTrigger else { return .unchanged }

        let preferredTail = max(keepRecent, 1)
        guard context.conversationThread.count > 1 else { return .unchanged }
        guard !request.conversation.isEmpty else {
            throw AgentRuntimeError.configurationError(
                "Context compaction requires a prepared conversation section"
            )
        }

        let hardLimit = max(window, 1)
        let effectiveOutputReserve = budget.outputReserve(maximum: outputReserve)
        let retainedTarget = max(
            0,
            hardLimit - effectiveOutputReserve - toolResultReserve
        )
        let preferredCuts = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - preferredTail,
            assistantSender: context.agentID.rawValue
        )
        let fallbackCuts = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - 1,
            assistantSender: context.agentID.rawValue
        )
        let cuts = Self.compactionCuts(
            preferred: preferredCuts,
            fallback: fallbackCuts
        )

        for archivedCount in cuts {
            let archived = Array(context.conversationThread.prefix(archivedCount))
            let summary = try await summarizeInBoundedChunks(
                context: context,
                archived: archived,
                window: hardLimit,
                outputReserve: effectiveOutputReserve,
                summarize: summarize,
                measure: measure
            )
            let candidateContext = Self.compactedContext(
                context,
                summary: summary,
                archivedCount: archivedCount
            )
            let assembledCandidate = assemble(candidateContext)
                .appending(suffix: request.suffix, tools: request.tools)
            let candidateRequest = assembledCandidate.withInput(
                request.input(for: assembledCandidate.messages)
            )
            let candidateCount = try await self.measure(
                candidateRequest,
                fallback: estimator,
                measure: measure
            )
            guard candidateCount <= retainedTarget else { continue }

            return .compacted(
                ConversationCompaction(summary: summary, archivedCount: archivedCount)
            )
        }

        // A provider-reported overflow must not be sent back unchanged when
        // no valid compacted request fits. Normal threshold checks leave the
        // final decision to the provider, preserving the existing behavior for
        // contexts whose oversized part cannot be archived.
        if trigger == .contextLengthExceeded {
            throw AgentRuntimeError.contextLengthExceeded
        }
        return .unchanged
    }

    /// Summarizes an archived prefix in bounded groups. A single large tool
    /// result or transcript must not make the summarization request itself
    /// exceed the same model window used for generation. Each completed chunk
    /// is folded into the next chunk's prior summary, producing one rolling
    /// summary and one atomic compaction event.
    private func summarizeInBoundedChunks(
        context: PromptContext,
        archived: [ChatMessage],
        window: Int,
        outputReserve: Int,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String,
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> String {
        let summaryBudget = max(1, window - outputReserve)
        var rollingSummary = context.contextSummary
        var pending: [ChatMessage] = []
        var groups = Self.messageGroups(
            archived,
            assistantSender: context.agentID.rawValue
        )
        var groupIndex = 0

        while groupIndex < groups.count {
            let group = groups[groupIndex]
            let candidate = pending + group
            let candidatePrompt = SummaryPrompt.messages(
                priorSummary: rollingSummary,
                archived: candidate,
                agentID: context.agentID
            )
            let candidateCost = try await self.measure(
                context: context,
                messages: candidatePrompt,
                tools: [],
                measure: measure
            )
            if candidateCost <= summaryBudget {
                pending = candidate
                groupIndex += 1
                continue
            }

            if !pending.isEmpty {
                rollingSummary = try await summarize(
                    CompactionSummaryRequest(
                        messages: SummaryPrompt.messages(
                            priorSummary: rollingSummary,
                            archived: pending,
                            agentID: context.agentID
                        ),
                        maxOutputTokens: outputReserve
                    )
                )
                pending = []
                // Re-evaluate the same group with the newly folded summary.
                // The summary itself consumes input space too.
                continue
            }

            // A semantic interaction is normally kept indivisible, but the
            // summary request has a different boundary from the retained
            // transcript. Split only its summary representation here. The
            // journaled conversation and the tool-call/result relationship
            // remain untouched in the resulting compaction event.
            let fragments = try await summaryFragments(
                group,
                context: context,
                priorSummary: rollingSummary,
                budget: summaryBudget,
                measure: measure
            )
            groups.replaceSubrange(groupIndex...groupIndex, with: fragments)
        }

        guard !pending.isEmpty else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced no summary input")
        }
        return try await summarize(
            CompactionSummaryRequest(
                messages: SummaryPrompt.messages(
                    priorSummary: rollingSummary,
                    archived: pending,
                    agentID: context.agentID
                ),
                maxOutputTokens: outputReserve
            )
        )
    }

    /// Breaks an oversized semantic interaction into bounded summary-only
    /// fragments. This is deliberately separate from `validCuts`: a retained
    /// conversation must not split a tool interaction, but a summarization
    /// prompt may represent a large tool result in several ordered pieces.
    private func summaryFragments(
        _ group: [ChatMessage],
        context: PromptContext,
        priorSummary: String?,
        budget: Int,
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> [[ChatMessage]] {
        var maximumCharacters = max(32, budget * 2)

        while true {
            let fragments = group.flatMap {
                Self.splitForSummary(
                    $0,
                    maximumCharacters: maximumCharacters,
                    agentID: context.agentID
                )
            }.map { [$0] }

            var fits = true
            for fragment in fragments {
                let prompt = SummaryPrompt.messages(
                    priorSummary: priorSummary,
                    archived: fragment,
                    agentID: context.agentID
                )
                if try await self.measure(
                    context: context,
                    messages: prompt,
                    tools: [],
                    measure: measure
                ) > budget {
                    fits = false
                    break
                }
            }
            if fits {
                return fragments
            }
            guard maximumCharacters > 1 else {
                throw AgentRuntimeError.contextLengthExceeded
            }
            maximumCharacters = max(1, maximumCharacters / 2)
        }
    }

    private static func splitForSummary(
        _ message: ChatMessage,
        maximumCharacters: Int,
        agentID: AgentID
    ) -> [ChatMessage] {
        switch message {
        case .text(let sender, let content, let timestamp):
            return contentChunks(content, maximumCharacters: maximumCharacters).map {
                .text(sender: sender, content: $0, timestamp: timestamp)
            }

        case .response(let sender, let payload, let timestamp):
            let content = String(decoding: payload, as: UTF8.self)
            return contentChunks(content, maximumCharacters: maximumCharacters).map {
                .text(sender: sender, content: $0, timestamp: timestamp)
            }

        case .toolResult(let id, let content, let timestamp):
            return contentChunks(content, maximumCharacters: maximumCharacters).map {
                .toolResult(id: id, content: $0, timestamp: timestamp)
            }

        case .toolCall(let calls, let timestamp):
            let rendered = calls.map {
                "\($0.name)(\($0.arguments.json))"
            }.joined(separator: ", ")
            return contentChunks(
                "assistant called tools: \(rendered)",
                maximumCharacters: maximumCharacters
            ).map {
                .text(sender: agentID.rawValue, content: $0, timestamp: timestamp)
            }

        case .assistantToolCall(let content, let thinking, let calls, let timestamp):
            let rendered = calls.map {
                "\($0.name)(\($0.arguments.json))"
            }.joined(separator: ", ")
            let reasoning = thinking.map { " reasoning: \($0)" } ?? ""
            return contentChunks(
                "assistant: \(content)\(reasoning) called tools: \(rendered)",
                maximumCharacters: maximumCharacters
            ).map {
                .text(sender: agentID.rawValue, content: $0, timestamp: timestamp)
            }

        case .failure, .decisionRequest, .decisionResolved:
            return [message]
        }
    }

    private static func contentChunks(
        _ content: String,
        maximumCharacters: Int
    ) -> [String] {
        let characters = Array(content)
        guard !characters.isEmpty else { return [""] }
        let size = max(1, maximumCharacters)
        return stride(from: 0, to: characters.count, by: size).map { start in
            let end = min(start + size, characters.count)
            return String(characters[start..<end])
        }
    }

    // MARK: - Budget fitting

    /// Starts with the largest archive that preserves the preferred recent
    /// tail. If that rebuilt request is still too large, progressively archives
    /// more complete interactions from the fallback boundaries.
    private static func compactionCuts(
        preferred: [Int],
        fallback: [Int]
    ) -> [Int] {
        let preferredCut = preferred.last(where: { $0 > 0 })
        let minimumFallbackCut = preferredCut ?? 0
        let additionalCuts = fallback.filter { $0 > minimumFallbackCut }
        if let preferredCut {
            return [preferredCut] + additionalCuts
        }
        return additionalCuts
    }

    private static func compactedContext(
        _ context: PromptContext,
        summary: String,
        archivedCount: Int
    ) -> PromptContext {
        PromptContext(
            agentID: context.agentID,
            definition: context.definition,
            workingMemory: context.workingMemory,
            contextSummary: summary,
            conversationThread: Array(context.conversationThread.dropFirst(archivedCount)),
            contextManifest: context.contextManifest,
            instructions: context.instructions
        )
    }

    /// Returns archive boundaries that do not split a tool call from any of
    /// its results. A cut at `n` archives `0..<n` and retains `n...`.
    private static func validCuts(
        in thread: [ChatMessage],
        maximum: Int,
        assistantSender: String
    ) -> [Int] {
        let groups = interactionBounds(in: thread, assistantSender: assistantSender)
        return (0...max(0, maximum)).filter { cut in
            groups.allSatisfy { bounds in
                !(bounds.first < cut && bounds.last >= cut)
            }
        }
    }

    /// Groups a tool-call message with every result belonging to it. This is
    /// used while chunking summary input so a summarizer never sees half of a
    /// parallel tool interaction.
    private static func messageGroups(
        _ messages: [ChatMessage],
        assistantSender: String
    ) -> [[ChatMessage]] {
        let interactions = interactionBounds(in: messages, assistantSender: assistantSender)
        let byStart = Dictionary(uniqueKeysWithValues: interactions.map { ($0.first, $0) })
        var groups: [[ChatMessage]] = []
        var index = 0
        while index < messages.count {
            let end = byStart[index]?.last ?? index
            let groupEnd = min(end, messages.count - 1)
            groups.append(Array(messages[index...groupEnd]))
            index = groupEnd + 1
        }
        return groups
    }

    /// Finds tool interactions by occurrence, not by globally unique tool ID.
    /// IDs are only used to associate a result with the earliest still-open
    /// call occurrence; repeated IDs in later rounds therefore remain separate.
    private static func interactionBounds(
        in messages: [ChatMessage],
        assistantSender: String
    ) -> [(first: Int, last: Int)] {
        var groups: [(first: Int, last: Int)] = []
        var pending: [String: [Int]] = [:]

        for (index, message) in messages.enumerated() {
            switch message {
            case .toolCall(let calls, _):
                let first: Int
                if index > 0,
                    case .text(let sender, _, _) = messages[index - 1], sender == assistantSender
                {
                    first = index - 1
                } else {
                    first = index
                }
                let groupIndex = groups.count
                groups.append((first: first, last: index))
                for call in calls {
                    pending[call.id, default: []].append(groupIndex)
                }

            case .toolResult(let id, _, _):
                if var occurrences = pending[id], !occurrences.isEmpty {
                    let groupIndex = occurrences.removeFirst()
                    pending[id] = occurrences
                    groups[groupIndex].last = max(groups[groupIndex].last, index)
                } else {
                    // Orphaned results are still indivisible transcript items.
                    groups.append((first: index, last: index))
                }

            default:
                break
            }
        }

        // A delayed result can make interactions overlap. Merge overlapping
        // ranges so no valid boundary can split either interaction.
        let sorted = groups.sorted { $0.first < $1.first }
        var merged: [(first: Int, last: Int)] = []
        for group in sorted {
            if let last = merged.indices.last, group.first <= merged[last].last {
                merged[last].last = max(merged[last].last, group.last)
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    /// Measures a candidate with the endpoint's tokenizer when one was
    /// injected by the runtime. Unsupported counting uses the estimator;
    /// failure of a supported counter propagates.
    private func measure(
        context: PromptContext,
        messages: [LLMMessage],
        tools: [LLMToolSchema],
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> Int {
        try await self.measure(
            PreparedRequest(
                prefix: [],
                conversation: messages.enumerated().map {
                    PreparedRequest.ConversationEntry(sourceIndex: $0.offset, message: $0.element)
                },
                tools: tools
            ),
            fallback: estimator,
            measure: measure
        )
    }

    private func measure(
        _ request: PreparedRequest,
        fallback estimator: TokenEstimator
    ) async throws(AgentRuntimeError) -> Int {
        try await estimator.estimate(messages: request.messages, tools: request.tools)
    }

    private func measure(
        _ request: PreparedRequest,
        fallback estimator: TokenEstimator,
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> Int {
        if let measure {
            return try await measure(request).tokenCount
        }
        return try await self.measure(request, fallback: estimator)
    }

    private func measure(
        messages: [LLMMessage],
        tools: [LLMToolSchema],
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> Int {
        try await self.measure(
            PreparedRequest(
                prefix: [],
                conversation: messages.enumerated().map {
                    PreparedRequest.ConversationEntry(sourceIndex: $0.offset, message: $0.element)
                },
                tools: tools
            ),
            fallback: estimator,
            measure: measure
        )
    }
}
