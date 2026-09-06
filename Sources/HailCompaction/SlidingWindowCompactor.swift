import Foundation
import HailAgentRuntime
import HailCore

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
        summarize: @Sendable ([LLMMessage]) async throws(AgentRuntimeError) -> String
    ) async throws(AgentRuntimeError) -> CompactionDecision {
        try await compact(
            context: context,
            request: request,
            budget: budget,
            summarize: summarize,
            trigger: .threshold
        )
    }

    public func compact(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        summarize: @Sendable ([LLMMessage]) async throws(AgentRuntimeError) -> String,
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision {
        let window = budget.contextWindow
        let thresholdTrigger = Int(Double(window) * threshold)

        let used: Int
        if let projected = context.measurement.projectedTokenCount {
            used = projected
        } else {
            used = try await measure(context: context, request: request)
        }
        guard trigger == .contextLengthExceeded || used >= thresholdTrigger else { return .unchanged }

        let preferredTail = max(keepRecent, 1)
        guard context.conversationThread.count > 1 else { return .unchanged }
        guard !request.conversation.isEmpty else {
            throw AgentRuntimeError.configurationError(
                "Context compaction requires a prepared conversation section"
            )
        }

        let hardLimit = max(window, 1)
        let retainedTarget = max(0, hardLimit - outputReserve - toolResultReserve)
        let preferredCuts = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - preferredTail,
            assistantSender: context.agentID.rawValue
        )
        let forced = trigger == .contextLengthExceeded
        var selectedCut = try await selectCut(
            from: preferredCuts,
            context: context,
            request: request,
            retainedTarget: retainedTarget,
            requireProgress: forced
        )

        // `keepRecent` is a preference, not a hard safety gate. If the
        // preferred suffix cannot fit, retain the smallest complete suffix
        // that can, down to one semantic message. This also gives a forced
        // recovery request a way to make progress when the normal estimate
        // missed provider-side costs.
        if selectedCut == nil {
            let fallbackCuts = Self.validCuts(
                in: context.conversationThread,
                maximum: context.conversationThread.count - 1,
                assistantSender: context.agentID.rawValue
            )
            selectedCut = try await selectCut(
                from: fallbackCuts,
                context: context,
                request: request,
                retainedTarget: retainedTarget,
                requireProgress: forced
            )
            if selectedCut == nil, forced {
                // The provider has already established that the request is
                // too large. In recovery mode, progress is more important
                // than satisfying Hail's estimate: archive the largest
                // complete prefix available and let the bounded summarizer
                // decide whether that prefix itself is representable.
                selectedCut = fallbackCuts.last(where: { $0 > 0 })
            }
        }

        guard let archivedCount = selectedCut else {
            // Hail does not turn an estimate into a terminal provider error.
            // The endpoint gets to make the final decision; a reported
            // overflow can come back through the trigger-aware path above.
            return .unchanged
        }
        guard archivedCount > 0 else { return .unchanged }

        let archived = Array(context.conversationThread.prefix(archivedCount))
        let summary = try await summarizeInBoundedChunks(
            context: context,
            archived: archived,
            window: hardLimit,
            summarize: summarize
        )
        return .compacted(
            ConversationCompaction(summary: summary, archivedCount: archivedCount)
        )
    }

    private func selectCut(
        from cuts: [Int],
        context: PromptContext,
        request: PreparedRequest,
        retainedTarget: Int,
        requireProgress: Bool
    ) async throws(AgentRuntimeError) -> Int? {
        let candidates = requireProgress ? cuts.filter { $0 > 0 } : cuts
        guard !candidates.isEmpty else { return nil }

        // Find the smallest archive prefix whose complete request fits the
        // retained target. Since removing an older prefix only removes tokens,
        // valid cuts are monotonic and can be searched without trying every
        // possible suffix.
        var lower = 0
        var upper = candidates.count - 1
        var selectedCut: Int?
        while lower <= upper {
            let middle = (lower + upper) / 2
            let cut = candidates[middle]
            let candidate = request.retainingConversation(after: cut)
            let count = try await measure(context: context, request: candidate)
            if count <= retainedTarget {
                selectedCut = cut
                upper = middle - 1
            } else {
                lower = middle + 1
            }
        }
        return selectedCut
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
        summarize: @Sendable ([LLMMessage]) async throws(AgentRuntimeError) -> String
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
            let candidateCost = try await measure(
                context: context,
                messages: candidatePrompt,
                tools: []
            )
            if candidateCost <= summaryBudget {
                pending = candidate
                groupIndex += 1
                continue
            }

            if !pending.isEmpty {
                rollingSummary = try await summarize(
                    SummaryPrompt.messages(
                        priorSummary: rollingSummary,
                        archived: pending,
                        agentID: context.agentID
                    ))
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
                budget: summaryBudget
            )
            groups.replaceSubrange(groupIndex...groupIndex, with: fragments)
        }

        guard !pending.isEmpty else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced no summary input")
        }
        return try await summarize(
            SummaryPrompt.messages(
                priorSummary: rollingSummary,
                archived: pending,
                agentID: context.agentID
            ))
    }

    /// Breaks an oversized semantic interaction into bounded summary-only
    /// fragments. This is deliberately separate from `validCuts`: a retained
    /// conversation must not split a tool interaction, but a summarization
    /// prompt may represent a large tool result in several ordered pieces.
    private func summaryFragments(
        _ group: [ChatMessage],
        context: PromptContext,
        priorSummary: String?,
        budget: Int
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
                if try await measure(context: context, messages: prompt, tools: []) > budget {
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
        tools: [LLMToolSchema]
    ) async throws(AgentRuntimeError) -> Int {
        try await measure(
            context: context,
            request: PreparedRequest(
                prefix: [],
                conversation: messages.enumerated().map {
                    PreparedRequest.ConversationEntry(sourceIndex: $0.offset, message: $0.element)
                },
                tools: tools
            )
        )
    }

    private func measure(
        context: PromptContext,
        request: PreparedRequest
    ) async throws(AgentRuntimeError) -> Int {
        let input = request.input(for: request.messages)
        switch context.measurement.tokenCounting {
        case .available(let counter):
            return max(0, try await counter(request.messages, request.tools))
        case .availableInput(let counter):
            return max(0, try await counter(input, request.tools))
        case .unavailable:
            return try await estimator.estimate(messages: request.messages, tools: request.tools)
        }
    }
}
