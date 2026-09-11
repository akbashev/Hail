import AnyLanguageModel
import HailAgentRuntime
import HailCore

/// Selects one safe archive boundary and performs one compaction request.
/// The model operation itself belongs to the agent loop; this value only owns
/// the pure transcript-boundary policy and budget checks.
public struct SlidingWindowCompactor: ContextCompactor {
    public var estimator: TokenEstimator
    public var threshold: Double
    public var keepRecent: Int
    public var outputReserve: Int
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

    public func compact<Output: Codable & Sendable & Generable>(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measurement: RequestMeasurement? = nil,
        measure: RequestMeasurer? = nil,
        assemble: PromptAssembler = assembleStandardPrompt,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
        contextProjection: @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError) -> GeneratedContent = {
            value, _ in value.generatedContent
        },
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
        let window = budget.contextWindow
        let thresholdTrigger = Int(Double(window) * threshold)
        let used = try await measured(
            request,
            provided: measurement,
            measure: measure
        )
        guard trigger == .contextLengthExceeded || used >= thresholdTrigger else {
            return .unchanged
        }
        guard context.conversationThread.count > max(keepRecent, 1),
            !request.conversation.isEmpty
        else {
            return .unchanged
        }

        let outputBudget = budget.outputReserve(maximum: outputReserve)
        let retainedBudget = max(1, window - outputBudget - toolResultReserve)
        let preferred = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - max(keepRecent, 1),
            assistantSender: context.agentID.rawValue
        )
        let fallback = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - 1,
            assistantSender: context.agentID.rawValue
        )
        let cuts = Self.compactionCuts(preferred: preferred, fallback: fallback)

        // Boundary selection is deliberately completed before generation. It
        // ensures the following call is the only compaction model request.
        // We iterate smallest-archive-first so the maximal keepRecent tail is
        // kept verbatim; we escalate to larger cuts only when the non-summary
        // parts of the rebuilt request would not fit.
        var selected: (count: Int, entries: [Transcript.Entry])?
        var selectedSummaryBudget = outputBudget
        for count in cuts {
            let keptRequest = Self.keptRequest(
                context: context,
                cut: count,
                assemble: assemble,
                originalRequest: request
            )
            let keptCost = try await measured(keptRequest, provided: nil, measure: measure)
            if keptCost <= retainedBudget {
                selectedSummaryBudget = max(0, min(outputBudget, retainedBudget - keptCost))
                let entries = SummaryPrompt.entries(
                    priorSummary: context.contextSummary,
                    archived: Array(context.conversationThread.prefix(count)),
                    agentID: context.agentID
                )
                selected = (count, entries)
                break
            }
        }

        guard let selected else {
            if trigger == .contextLengthExceeded {
                throw AgentRuntimeError.contextLengthExceeded
            }
            return .unchanged
        }

        let output = try await summarize(
            CompactionSummaryRequest(
                entries: selected.entries,
                maxOutputTokens: max(1, selectedSummaryBudget)
            )
        )
        let projectionBudget = ContextProjectionBudget(
            availableTokens: selectedSummaryBudget,
            outputReserve: selectedSummaryBudget
        )
        let contextValue = try contextProjection(output, projectionBudget)
        let candidate = Self.compactedContext(
            context,
            summary: contextValue,
            archivedCount: selected.count
        )
        let candidateRequest = assemble(candidate)
            .appending(suffix: request.suffix, tools: request.tools)
        let candidateCost = try await measured(
            candidateRequest,
            provided: nil,
            measure: measure
        )
        guard candidateCost <= retainedBudget else {
            // The rebuilt request still does not fit the retained budget. A
            // threshold decision may stay with the current context; a
            // provider-reported overflow has nothing left to retry and must
            // propagate the typed failure.
            if trigger == .contextLengthExceeded {
                throw AgentRuntimeError.contextLengthExceeded
            }
            return .unchanged
        }

        return .compacted(
            CompactionResult(
                output: output,
                context: contextValue,
                archivedCount: selected.count
            )
        )
    }

    private static func keptRequest(
        context: PromptContext,
        cut: Int,
        assemble: PromptAssembler,
        originalRequest: PreparedRequest
    ) -> PreparedRequest {
        let kept = Array(context.conversationThread.dropFirst(cut))
        let keptContext = PromptContext(
            agentID: context.agentID,
            definition: context.definition,
            contextSummary: nil,  // summary cost is added separately as outputBudget
            conversationThread: kept,
            contextManifest: context.contextManifest,
            instructions: context.instructions
        )
        return assemble(keptContext)
            .appending(suffix: originalRequest.suffix, tools: originalRequest.tools)
    }

    private func measured(
        _ request: PreparedRequest,
        provided: RequestMeasurement?,
        measure: RequestMeasurer?
    ) async throws(AgentRuntimeError) -> Int {
        if let provided { return provided.tokenCount }
        if let measure { return try await measure(request).tokenCount }
        return try await estimator.estimate(messages: request.entries, tools: request.tools)
    }

    private static func compactionCuts(preferred: [Int], fallback: [Int]) -> [Int] {
        let preferredCut = preferred.last(where: { $0 > 0 })
        let additional = fallback.filter { $0 > (preferredCut ?? 0) }
        return preferredCut.map { [$0] + additional } ?? additional
    }

    private static func compactedContext(
        _ context: PromptContext,
        summary: GeneratedContent,
        archivedCount: Int
    ) -> PromptContext {
        PromptContext(
            agentID: context.agentID,
            definition: context.definition,
            contextSummary: summary,
            conversationThread: Array(context.conversationThread.dropFirst(archivedCount)),
            contextManifest: context.contextManifest,
            instructions: context.instructions
        )
    }

    private static func validCuts(
        in thread: [ChatMessage],
        maximum: Int,
        assistantSender: String
    ) -> [Int] {
        let groups = interactionBounds(in: thread, assistantSender: assistantSender)
        return (0...max(0, maximum)).filter { cut in
            groups.allSatisfy { !($0.first < cut && $0.last >= cut) }
        }
    }

    private static func interactionBounds(
        in messages: [ChatMessage],
        assistantSender: String
    ) -> [(first: Int, last: Int)] {
        var groups: [(first: Int, last: Int)] = []
        var pending: [String: [Int]] = [:]

        for (index, message) in messages.enumerated() {
            switch message {
            case .toolCall(let calls, _):
                let first: Int =
                    if index > 0,
                        case .text(let sender, _, _) = messages[index - 1], sender == assistantSender
                    { index - 1 } else { index }
                let group = groups.count
                groups.append((first, index))
                for call in calls { pending[call.id, default: []].append(group) }

            case .assistantToolCall(let round, _):
                let group = groups.count
                groups.append((index, index))
                for call in round.calls { pending[call.id, default: []].append(group) }

            case .toolResult(let id, _, _, _):
                if var occurrences = pending[id], !occurrences.isEmpty {
                    let group = occurrences.removeFirst()
                    pending[id] = occurrences
                    groups[group].last = max(groups[group].last, index)
                } else {
                    groups.append((index, index))
                }

            default:
                break
            }
        }

        return groups.sorted { $0.first < $1.first }.reduce(into: []) { result, group in
            if let index = result.indices.last, group.first <= result[index].last {
                result[index].last = max(result[index].last, group.last)
            } else {
                result.append(group)
            }
        }
    }
}
