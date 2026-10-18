import AnyLanguageModel
import HailAgentRuntime
import HailCore

/// Folds the oldest history into the summary, one compaction request at a time, keeping the most
/// recent history whole within a share of the window: so an 8K window keeps the last few calls,
/// and a 256K one a long stretch.
///
/// What was said to the agent stays word for word, newest first, within a share of the window of
/// its own; the work on it — calls, results, answers — is what the summary replaces. The cut can
/// fall inside the turn being worked on, after a call's result: its input always stays, last.
///
/// The model operation itself belongs to the agent loop; this value only owns the policy: which
/// turns to fold, which inputs to keep, and the budget checks.
public struct SlidingWindowCompactor: ContextCompactor {
    public var estimator: TokenEstimator
    public var threshold: Double
    /// The share of the window the most recent history may take, kept whole.
    public var keepRecentShare: Double
    public var outputReserve: Int
    public var toolResultReserve: Int
    /// Multiplier applied to the retained budget when candidate fitting runs on the fallback
    /// estimator instead of an exact provider counter. The estimator undercounts rendered chat
    /// templates, so an unmargined "fitting" fold can still overflow the real window.
    public var fittingMargin: Double
    /// Minimum tokens a fold must leave for the projected summary. Folds that squeeze the summary
    /// to nothing are skipped in favor of deeper ones; an empty summary would drop history.
    public var minimumSummaryBudget: Int
    /// The share of the window archived inputs may take, word for word, newest first.
    public var keptInputsShare: Double

    public init(
        estimator: TokenEstimator = .init(),
        threshold: Double = 0.8,
        keepRecentShare: Double = 0.3,
        outputReserve: Int = 512,
        toolResultReserve: Int = 512,
        fittingMargin: Double = 0.75,
        minimumSummaryBudget: Int = 256,
        keptInputsShare: Double = 0.2
    ) {
        self.estimator = estimator
        self.threshold = threshold
        self.keepRecentShare = min(1, max(0, keepRecentShare))
        self.outputReserve = max(0, outputReserve)
        self.toolResultReserve = max(0, toolResultReserve)
        self.fittingMargin = min(1, max(0.1, fittingMargin))
        self.minimumSummaryBudget = max(0, minimumSummaryBudget)
        self.keptInputsShare = min(1, max(0, keptInputsShare))
    }

    public func compact<Output: Codable & Sendable & Generable>(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measuring: RequestMeasuring = .estimated,
        assemble: PromptAssembler = assembleStandardPrompt,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
        contextProjection: @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError) -> GeneratedContent = {
            value, _ in value.generatedContent
        },
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
        let window = budget.contextWindow
        let used = try await currentSize(of: request, measuring: measuring)
        guard trigger == .contextLengthExceeded || used >= Int(Double(window) * threshold) else {
            return .unchanged
        }
        let history = context.history
        let outputBudget = budget.outputReserve(maximum: outputReserve)
        let retained = retainedBudget(window: window, outputBudget: outputBudget, measuring: measuring)
        let inputBudget = Int(Double(window) * keptInputsShare)
        let recentBudget = Int(Double(window) * keepRecentShare)

        // The shallowest fold that fits with room for the summary wins; the shallowest that only
        // fits is the last resort. Choosing is done before the one compaction model request.
        var selection = Selection.searching(lastResort: nil)
        for through in cuts(history, keeping: recentBudget, trigger: trigger) {
            if case .chosen = selection { break }
            let kept = try keptInputs(history, through: through, budget: inputBudget)
            let fold = try Self.fold(history, through: through, kept: kept)
            let cost = try await candidateSize(
                of: assemble(context.with(history: fold.summarized(by: .unwritten)))
                    .offering(request.tools),
                measuring: measuring)
            selection = selection.considering(
                Candidate(through: through, kept: kept, fold: fold, cost: cost),
                retained: retained, minimumSummary: minimumSummaryBudget)
        }
        guard let candidate = selection.choice else {
            if trigger == .contextLengthExceeded { throw AgentRuntimeError.contextLengthExceeded }
            return .unchanged
        }

        let summaryBudget = candidate.summaryBudget(retained: retained, outputBudget: outputBudget)
        let output = try await summarize(
            CompactionSummaryRequest(
                entries: SummaryPrompt.entries(
                    priorSummary: history.earlier?.summary,
                    fold: candidate.fold,
                    task: CompactionTask.instructions(for: Output.self),
                    outputBudget: summaryBudget),
                maxOutputTokens: max(1, summaryBudget)))
        let contextValue = try contextProjection(
            output, ContextProjectionBudget(availableTokens: summaryBudget, outputReserve: summaryBudget))
        let compacted = candidate.fold.summarized(
            by: AgentHistory.Summary(context: contextValue, report: output.generatedContent))
        let compactedSize = try await candidateSize(
            of: assemble(context.with(history: compacted)).offering(request.tools),
            measuring: measuring)
        guard compactedSize <= retained else {
            // The rebuilt request still doesn't fit. A threshold decision may stay with the
            // current context; a provider-reported overflow has nothing left to retry.
            if trigger == .contextLengthExceeded { throw AgentRuntimeError.contextLengthExceeded }
            return .unchanged
        }
        return .compacted(
            CompactionResult(output: output, context: contextValue, through: candidate.through, kept: candidate.kept))
    }

    /// Where to cut, in the order to try them: first the shallowest cut that keeps what comes
    /// after it within `budget` — the closed turns, oldest folded first, then the open turn's
    /// work, a call and its result at a time — then deeper ones, keeping less, since keeping recent
    /// history is a preference, never a wall. Past the threshold, a history that fits `budget`
    /// whole is left as it is.
    func cuts(_ history: AgentHistory, keeping budget: Int, trigger: ContextCompactionTrigger) -> [AgentHistory.Cut] {
        let work = history.open?.steps ?? []
        let workCost = work.map(cost)
        // After each closed turn, oldest first: what's kept is the later turns and all the work.
        let afterTurns = history.closed.indices.map { index in
            (
                cut: AgentHistory.Cut.after(history.closed[index].id),
                kept: history.closed[(index + 1)...].map(cost).reduce(0, +) + workCost.reduce(0, +)
            )
        }
        // Inside the open turn, after each result: what's kept is the work after it.
        let insideWork: [(cut: AgentHistory.Cut, kept: Int)] =
            history.open.map { open in
                work.indices.compactMap { index in
                    guard case .resulted = work[index] else { return nil }
                    return (.within(open.id, steps: index + 1), workCost[(index + 1)...].reduce(0, +))
                }
            } ?? []
        let all = afterTurns + insideWork
        let whole = history.closed.map(cost).reduce(0, +) + workCost.reduce(0, +)
        if trigger == .threshold, whole <= budget { return [] }
        let first = all.firstIndex { $0.kept <= budget } ?? all.indices.last ?? 0
        return all.isEmpty ? [] : all[first...].map(\.cut)
    }

    /// What a closed turn takes in a request: what was said, the answer, and the results that
    /// landed on pages, which earlier turns keep.
    private func cost(_ turn: AgentHistory.ClosedTurn) -> Int {
        let answer: Int =
            switch turn.outcome {
            case .replied(let reply): estimator.estimate(Self.text(of: reply.content))
            case .failed, .cancelled, .interrupted: 0
            }
        let landed = turn.steps.map { step in
            if case .resulted(let result, _) = step, result.landed != nil { cost(step) } else { 0 }
        }
        return estimator.estimate(Self.text(of: turn.input.content)) + answer + landed.reduce(0, +)
    }

    /// What one step of work takes in a request: a call with its arguments, or a result.
    private func cost(_ step: AgentHistory.Step) -> Int {
        switch step {
        case .called(let call, _): estimator.estimate(call.name + call.arguments.jsonString)
        case .resulted(let result, _): estimator.estimate(result.output.textRepresentation)
        case .noticed(let notice, _): estimator.estimate(notice.words)
        }
    }

    /// The earlier inputs that stay word for word after folding through `through`: the newest
    /// that fit `budget`.
    private func keptInputs(
        _ history: AgentHistory, through: AgentHistory.Cut, budget: Int
    ) throws(AgentRuntimeError) -> AgentHistory.KeptInputs {
        let inputs = try Self.fold(history, through: through, kept: .all).kept
        let newestFirst = inputs.reversed().map { (turn: $0.turn, cost: estimator.estimate(Self.text(of: $0.input.content))) }
        let totals = newestFirst.reduce(into: [Int]()) { $0.append(($0.last ?? 0) + $1.cost) }
        let fitting = totals.prefix { $0 <= budget }.count
        switch fitting {
        case 0: return .none
        case inputs.count: return .all
        default: return .from(newestFirst[fitting - 1].turn)
        }
    }

    /// A fold of a turn the history has: one it doesn't is the compactor's own bug.
    private static func fold(
        _ history: AgentHistory, through: AgentHistory.Cut, kept: AgentHistory.KeptInputs
    ) throws(AgentRuntimeError) -> AgentHistory.Fold {
        do {
            return try history.folding(through: through, kept: kept)
        } catch {
            throw .invalidHistory(error)
        }
    }

    private static func text(of content: GeneratedContent) -> String {
        if case .string(let text) = content.kind { return text }
        return content.jsonString
    }

    /// The tokens a compacted request may take. The estimator undercounts rendered chat
    /// templates, so with it the budget is margined.
    private func retainedBudget(window: Int, outputBudget: Int, measuring: RequestMeasuring) -> Int {
        let retained = max(1, window - outputBudget - toolResultReserve)
        switch measuring {
        case .counted: return retained
        case .reportedFloor, .estimated: return max(minimumSummaryBudget + 1, Int(Double(retained) * fittingMargin))
        }
    }

    private func currentSize(of request: PreparedRequest, measuring: RequestMeasuring) async throws(AgentRuntimeError) -> Int {
        switch measuring {
        case .counted(let current, _), .reportedFloor(let current): current.tokenCount
        case .estimated: try await estimator.estimate(messages: request.entries, tools: request.tools)
        }
    }

    private func candidateSize(of request: PreparedRequest, measuring: RequestMeasuring) async throws(AgentRuntimeError) -> Int {
        switch measuring {
        case .counted(_, let count): try await count(request).tokenCount
        case .reportedFloor, .estimated: try await estimator.estimate(messages: request.entries, tools: request.tools)
        }
    }
}

/// One way to compact: fold the work through a turn, keep these earlier inputs; `cost` is what
/// stays, with the summary still unwritten.
struct Candidate {
    let through: AgentHistory.Cut
    let kept: AgentHistory.KeptInputs
    let fold: AgentHistory.Fold
    let cost: Int

    func summaryBudget(retained: Int, outputBudget: Int) -> Int {
        min(outputBudget, retained - cost)
    }
}

/// Choosing a candidate, shallowest first.
enum Selection {
    /// Still looking; a candidate that fits, with too little room for the summary, is the last
    /// resort.
    case searching(lastResort: Candidate?)
    /// One that fits with room for the summary.
    case chosen(Candidate)

    func considering(_ candidate: Candidate, retained: Int, minimumSummary: Int) -> Selection {
        guard case .searching(let lastResort) = self, candidate.cost <= retained else { return self }
        if retained - candidate.cost >= minimumSummary { return .chosen(candidate) }
        return .searching(lastResort: lastResort ?? candidate)
    }

    var choice: Candidate? {
        switch self {
        case .searching(let lastResort): lastResort
        case .chosen(let candidate): candidate
        }
    }
}
