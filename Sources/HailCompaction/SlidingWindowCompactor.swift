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
    /// Multiplier applied to the retained budget when candidate fitting runs
    /// on the fallback estimator instead of an exact provider counter. The
    /// estimator undercounts rendered chat templates, so an unmargined
    /// "fitting" cut can still overflow the real window.
    public var fittingMargin: Double
    /// Minimum tokens a cut must leave for the projected summary. Cuts that
    /// squeeze the summary to nothing are skipped in favor of deeper
    /// archives; an empty rolling summary would silently drop history.
    public var minimumSummaryBudget: Int

    public init(
        estimator: TokenEstimator = .init(),
        threshold: Double = 0.7,
        keepRecent: Int = 10,
        outputReserve: Int = 512,
        toolResultReserve: Int = 512,
        fittingMargin: Double = 0.75,
        minimumSummaryBudget: Int = 256
    ) {
        self.estimator = estimator
        self.threshold = threshold
        self.keepRecent = keepRecent
        self.outputReserve = max(0, outputReserve)
        self.toolResultReserve = max(0, toolResultReserve)
        self.fittingMargin = min(1, max(0.1, fittingMargin))
        self.minimumSummaryBudget = max(0, minimumSummaryBudget)
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
        // Recovery from a real overflow may always archive down to the
        // in-flight exchange; a threshold trigger leaves threads no larger
        // than the preferred tail alone.
        guard context.conversationThread.count > 1,
            !request.conversation.isEmpty
        else {
            return .unchanged
        }
        if trigger == .threshold && context.conversationThread.count <= max(keepRecent, 1) {
            return .unchanged
        }

        let outputBudget = budget.outputReserve(maximum: outputReserve)
        let retainedBudget = max(1, window - outputBudget - toolResultReserve)
        // Fitting decisions trust the measurement source. A provider counter
        // is exact; the fallback estimator counts Hail's serialization, which
        // provider chat templates render larger (observed ~30% on
        // tool-result-heavy contexts). Margin the budget for estimator
        // fitting so a "fitting" cut also fits in reality.
        let effectiveRetainedBudget =
            measure == nil
            ? max(minimumSummaryBudget + 1, Int(Double(retainedBudget) * fittingMargin))
            : retainedBudget
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
        // kept verbatim; we escalate to larger cuts when a candidate leaves
        // too little summary room or would not fit. A cut that keeps every
        // recent message is a preference, never a wall: recovery from a real
        // overflow must always be able to archive deeper.
        var selected: (count: Int, entries: [Transcript.Entry], summaryBudget: Int)?
        var lastResort: (count: Int, entries: [Transcript.Entry], summaryBudget: Int)?
        for count in cuts {
            let keptRequest = Self.keptRequest(
                context: context,
                cut: count,
                assemble: assemble,
                originalRequest: request
            )
            let keptCost = try await measured(keptRequest, provided: nil, measure: measure)
            guard keptCost <= effectiveRetainedBudget else { continue }
            let summaryRoom = effectiveRetainedBudget - keptCost
            let summaryBudget = min(outputBudget, summaryRoom)
            let entries = SummaryPrompt.entries(
                priorSummary: context.contextSummary,
                archived: Array(context.conversationThread.prefix(count)),
                agentID: context.agentID,
                task: CompactionTask.instructions(for: Output.self),
                outputBudget: summaryBudget
            )
            // The summary room is a preference among fitting cuts, never a
            // dead end: a deeper cut with real room always wins, but the
            // shallowest fitting cut remains the last resort.
            if summaryRoom >= minimumSummaryBudget {
                selected = (count, entries, summaryBudget)
                break
            }
            if lastResort == nil {
                lastResort = (count, entries, summaryBudget)
            }
        }

        guard let choice = selected ?? lastResort else {
            if trigger == .contextLengthExceeded {
                throw AgentRuntimeError.contextLengthExceeded
            }
            return .unchanged
        }

        let output = try await summarize(
            CompactionSummaryRequest(
                entries: choice.entries,
                maxOutputTokens: max(1, choice.summaryBudget)
            )
        )
        let projectionBudget = ContextProjectionBudget(
            availableTokens: choice.summaryBudget,
            outputReserve: choice.summaryBudget
        )
        let contextValue = try contextProjection(output, projectionBudget)
        let candidate = Self.compactedContext(
            context,
            summary: contextValue,
            archivedCount: choice.count
        )
        let candidateRequest = assemble(candidate)
            .appending(suffix: request.suffix, tools: request.tools)
        let candidateCost = try await measured(
            candidateRequest,
            provided: nil,
            measure: measure
        )
        guard candidateCost <= effectiveRetainedBudget else {
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
                archivedCount: choice.count
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
            modelConfiguration: context.modelConfiguration,
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
            modelConfiguration: context.modelConfiguration,
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
