import AnyLanguageModel
import HailCore
import HailModelRuntime
import Logging
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - Turn event projection

/// How a turn's request ended: with the generated value, or overflowing the model's context. An
/// overflow is recovered by compacting and asking again: compaction keeps every input and folds
/// the rest, the turn's calls so far included, into the summary, so the new request ends with the
/// input it answers.
private enum TurnRequestOutcome<Output> {
    case generated(Output)
    case overflowed(TurnCalls)
    /// The model's answer ran out while it was thinking, after the tools it called answered: the
    /// turn goes on from their results, told so.
    case ranOut(TurnCalls)
    /// The turn made all the tool calls it may make: the model is told so, and answers without
    /// tools.
    case outOfCalls(TurnCalls)
    /// The model answered, but not in the form asked for: it's told so, with what it wrote, and
    /// answers again.
    case outOfShape(TurnCalls, written: String)
}

/// A model request's value, before and after the model generates it.
enum Generation<Output: Sendable>: Sendable {
    case pending
    case generated(Output)
}

/// A turn's request as its events come: the turn's tool calls so far, and the value once
/// generated.
struct TurnProgress<Output: Sendable>: Sendable {
    let calls: TurnCalls
    let generation: Generation<Output>
}

/// The tool calls a turn made, as its limits count them: how many, against the turn's maximum,
/// and the failure the model last repeated. Each step either goes on or ends the turn with why.
struct TurnCalls: Sendable, Equatable {
    let limit: Int
    let count: Int
    let failures: ToolFailureTracker

    init(limit: Int, count: Int = 0, failures: ToolFailureTracker = ToolFailureTracker()) {
        self.limit = limit
        self.count = count
        self.failures = failures
    }

    /// The model calls a tool; a call past the limit is refused before it's journaled or run.
    func calling() throws(AgentRuntimeError) -> TurnCalls {
        guard count < limit else { throw .toolCallsRanOut(limit: limit) }
        return TurnCalls(limit: limit, count: count + 1, failures: failures)
    }

    /// A call's result; the same deterministic failure twice in a row is a loop, not recovery.
    func resulted(_ result: ToolResult) throws(AgentRuntimeError) -> TurnCalls {
        switch failures.recording(results: [result]) {
        case .tracking(let tracker):
            return TurnCalls(limit: limit, count: count, failures: tracker)
        case .repeated:
            throw .toolFailed(
                name: result.name,
                reason: "The model repeated the same failed tool call twice. \(result.output.textRepresentation)")
        }
    }
}

/// A compact description of deterministic failures produced by one tool
/// round. Unavailable and execution failures are deliberately excluded: the
/// model may be able to recover from those without changing its arguments.
/// Tool call IDs are intentionally excluded because providers generate a new
/// ID for each retry.
struct ToolFailureSignature: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let name: String
        let output: ToolOutput
        let failureKind: ToolFailureKind
    }

    let entries: [Entry]

    init(results: [ToolResult]) {
        self.entries =
            results
            .compactMap { result -> Entry? in
                guard let failureKind = result.failureKind,
                    failureKind == .invalidArguments || failureKind == .rejected
                else { return nil }
                return Entry(
                    name: result.name,
                    output: result.output,
                    failureKind: failureKind
                )
            }
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// Stops a reasoning turn when the model repeats the same failed tool round.
/// One repeat is allowed so the model can correct an ordinary malformed call;
/// a second identical failure is a loop, not useful recovery.
struct ToolFailureTracker: Sendable, Equatable {
    static let maximumRepetitions = 2

    private(set) var lastFailure: ToolFailureSignature?
    private(set) var repetitions = 0

    /// What recording results comes to: still tracking, or a failure repeated too often.
    enum Recorded: Equatable {
        case tracking(ToolFailureTracker)
        case repeated(ToolFailureSignature)
    }

    func recording(results: [ToolResult]) -> Recorded {
        let failure = ToolFailureSignature(results: results)
        guard !failure.isEmpty else { return .tracking(Self()) }
        let repetitions = failure == lastFailure ? self.repetitions + 1 : 1
        return repetitions >= Self.maximumRepetitions
            ? .repeated(failure)
            : .tracking(Self(lastFailure: failure, repetitions: repetitions))
    }
}

/// The only failures a reasoning loop can return to its host. Keeping the
/// lifecycle distinction in the type prevents the host from accidentally
/// closing a turn whose terminal failure was never emitted.
enum ReasoningLoopError: Error, Sendable, Equatable {
    case failed(AgentRuntimeError)
    case failureNotEmitted(AgentRuntimeError)
}

/// Pure reducer that turns a stream of ``ModelEvent`` values into typed
/// ``AgentRunEvent`` values. Progress (status, thinking, the reply so far, tools) is
/// recorded on the activity stream by the loop; control, typed partial
/// snapshots, and the typed outcome are emitted here.
enum TurnReducer {
    static func reduce<Output>(
        event: ModelEvent<Output>,
        at timestamp: Date
    ) -> [AgentRunEvent<Output>]
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        switch event {
        case .activity:
            return []

        case .toolCall(let toolCall):
            return [.toolRequested(toolCall: toolCall.call, at: timestamp)]

        case .generated(let value):
            return [.modelOutputGenerated(content: value, at: timestamp)]

        case .partialUpdated(let content):
            guard let partial = try? Output.PartiallyGenerated(content) else { return [] }
            return [.modelOutputPartialUpdated(content: partial, at: timestamp)]

        case .usage, .contextUsage:
            return []

        case .failed:
            return []
        }
    }
}

// MARK: - ReasoningLoop

/// The assembled context for one turn.
struct TurnContext: Sendable {
    /// The policy-owned request. Messages are always derived from this value,
    /// so prompt assembly and compaction cannot drift apart.
    var preparedRequest: PreparedRequest
    var entries: [Transcript.Entry] { preparedRequest.entries }
    /// The derived turn context from which the request was assembled; handed
    /// to the compactor independently from request accounting.
    let promptContext: PromptContext
    /// Occupancy the provider reported for the most recent request. The next
    /// request strictly grows on it, so it is a floor for threshold decisions
    /// when no preflight token counter exists. Consumed (cleared) once
    /// compaction acts on it.
    var latestContextUsage: ContextUsage? = nil
}

/// How a turn that didn't answer ends: failed, or cancelled by whoever asked. Cancellation — a raw
/// `CancellationError` from a consumer abort, or an endpoint reporting `.cancelled` — isn't a
/// failure, and must not replay as one.
enum TurnEnd: Equatable {
    case failed(AgentRuntimeError)
    case cancelled

    /// Normalizes the existential `catch` boundary around the typed turn: a value that isn't an
    /// `AgentRuntimeError` is an infrastructure failure.
    init(_ error: any Error) {
        switch error {
        case is CancellationError: self = .cancelled
        case let runtimeError as AgentRuntimeError:
            self = runtimeError == .cancelled ? .cancelled : .failed(runtimeError)
        default: self = .failed(.infrastructureFailure(String(describing: error)))
        }
    }

    var error: AgentRuntimeError {
        switch self {
        case .failed(let error): error
        case .cancelled: .cancelled
        }
    }

    func event(at date: Date) -> AgentHistory.Event {
        switch self {
        case .failed(let error): .failed(AgentHistory.Failure(error: error, at: date))
        case .cancelled: .cancelled(at: date)
        }
    }
}

/// How a turn starts: with something just said to the agent, which opens it; or resuming the
/// open turn a crash interrupted, which is already in the history.
enum TurnOpening: Sendable {
    case received(AgentHistory.Input)
    case resumed(AgentHistory.OpenTurn)

    var input: AgentHistory.Input {
        switch self {
        case .received(let input): input
        case .resumed(let turn): turn.input
        }
    }

    /// The tool calls the turn made before it starts here.
    var callsMade: Int {
        switch self {
        case .received: 0
        case .resumed(let turn): turn.steps.filter { if case .called = $0 { true } else { false } }.count
        }
    }
}

/// One turn's request: the host's typed input, and the request the model is sent for it.
struct TurnRequest<Input: Sendable>: Sendable {
    let value: Input
    let request: PreparedRequest
}

private func transcriptSegments(_ output: ToolOutput) -> [Transcript.Segment] {
    output.transcriptSegments
}

/// One agent turn, hosted as a value: builds context, drives the model/tool
/// loop, journals persistent events, forwards live updates, and broadcasts the
/// final generated value through the connection.
///
/// The loop owns no actor and no mutable state; every dependency is injected
/// as a closure by the host (an `Agent`, or any other event-sourced actor that
/// wants to think). This keeps the reasoning machinery concrete and composable
/// — dependencies are values, not protocols — and lets multiple actor types
/// share one implementation without inheriting from anything.
struct ReasoningLoop<ClockType: Clock>: Sendable where ClockType.Duration == Duration {
    /// The hosting agent's identity. Used to attribute journaled responses and
    /// to decide whether a `.response` message was authored by this agent.
    let agentID: AgentID

    /// Identity shared by all provider and summarization requests in this
    /// reasoning turn.
    let turnID: TurnID

    /// The effect authority this turn runs under (the turn's lane, or the
    /// agent's default).
    let authority: any Authority

    /// Builds the prompt context (system prompt, memory, agent history,
    /// context manifest) for one turn.
    let context: @Sendable () async throws(AgentRuntimeError) -> TurnContext

    /// Rebuilds the event-sourced part of a turn after a journal event. The
    /// argument is the turn's initial context, whose external inputs must stay
    /// stable while the model is working.
    let rebuildContext: @Sendable (TurnContext) async throws(AgentRuntimeError) -> TurnContext

    /// Resolves the model endpoint from the complete scoped turn context.
    /// This includes the validated provider-session resume handle; the host
    /// must not reread mutable agent state here.
    let endpoint: @Sendable (TurnContext) async throws(AgentRuntimeError) -> ModelEndpoint

    /// Selects a request-scoped reasoning override without requiring the
    /// endpoint to classify prompt text. The default preserves provider
    /// behavior.
    let modelReasoningPolicy: ModelReasoningPolicy

    /// Optional context compactor, consulted after each turn, and when a request overflows. See
    /// ``ContextCompactor``.
    let compactor: (any ContextCompactor)?

    /// The host may provide one typed report operation whose context projection
    /// is persisted by Hail. This keeps auxiliary product data in the same
    /// compaction request instead of launching a second model request.
    let compactionOperation: CompactionOperation?

    /// The host's pure prompt assembler. Compaction uses it to validate a
    /// candidate summary against the request that would actually be sent.
    let assemblePrompt: PromptAssembler

    /// Takes the agent's session for a turn, with the turn's tools offered in it.
    let session: @Sendable (AgentTurnContext) async throws(AgentRuntimeError) -> AgentSession
    /// Gives the agent's session back when the turn ends, however it ends.
    let keepSession: @Sendable (consuming AgentSession) async -> Void

    /// Emits a persistent agent event.
    let emit: @Sendable (AgentEvent) async throws(AgentRuntimeError) -> Void

    /// Records an ephemeral activity fragment (status/thinking/text/tool).
    let recordActivity: @Sendable (AgentActivity) async -> Void

    /// Ceiling on tool-call rounds within one turn. A model stuck in a
    /// tool-call loop would otherwise spin forever, growing the transcript
    /// (and the provider bill) without bound; exceeding the ceiling fails
    /// the turn as model misbehavior instead of hanging it.
    let maxToolRounds: Int

    private let logger: Logger
    /// Swift clock used for monotonic elapsed-time measurements. Event dates
    /// remain `Date` values because they are persisted and externally visible.
    let clock: ClockType

    /// Owns the durable lifecycle shared by generation and summarization
    /// requests. The caller only reduces provider events into its operation's
    /// result; starts, usage, completion, failure, and duration are uniform.
    /// A request that failed, and what its events had come to by then.
    struct RequestFailure<State: Sendable>: Error {
        let error: AgentRuntimeError
        let state: State
    }

    struct ModelRequestRunner: Sendable {
        let turnID: TurnID
        let emit: @Sendable (AgentEvent) async throws(AgentRuntimeError) -> Void
        let recordActivity: @Sendable (AgentActivity) async -> Void
        let clock: ClockType

        /// Runs the request, folding its events into `State` from `initial`.
        func run<Output, State: Sendable>(
            model: String,
            kind: ModelRequestKind,
            contentHashes: [String]? = nil,
            stream: AsyncStream<ModelEvent<Output>>,
            from initial: State,
            reduce: (State, ModelEvent<Output>) async throws(AgentRuntimeError) -> State
        ) async throws(RequestFailure<State>) -> State
        where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
            let requestID = ModelRequestID()
            let startedAt = clock.now
            do {
                try await started(requestID, model: model, kind: kind, contentHashes: contentHashes)
            } catch {
                throw RequestFailure(error: error, state: initial)
            }
            // The fold's accumulator, and the usage last reported, which completes the request.
            var state = initial
            var usage: ModelUsage?
            do {
                for await event in stream {
                    try ReasoningLoop<ClockType>.checkCancellation()
                    switch event {
                    case .usage(let requestUsage):
                        usage = requestUsage
                        try await emit(.modelUsage(requestUsage, at: Date()))
                        await recordActivity(.turn(.progress(.usage(requestUsage)), at: Date()))
                    case .contextUsage(let contextUsage):
                        try await emit(.contextUsage(contextUsage, at: Date()))
                        await recordActivity(.turn(.progress(.contextUsage(contextUsage)), at: Date()))
                    default:
                        break
                    }
                    state = try await reduce(state, event)
                }
                try ReasoningLoop<ClockType>.checkCancellation()
                try await emit(
                    .modelRequestCompleted(
                        id: requestID,
                        usage: usage,
                        durationMilliseconds: ReasoningLoop<ClockType>.durationMilliseconds(
                            since: startedAt, now: clock.now),
                        at: Date()
                    )
                )
                return state
            } catch {
                let requestError = error
                do {
                    try await emit(
                        .modelRequestFailed(
                            id: requestID,
                            error: ReasoningLoop<ClockType>.mapRequestError(requestError),
                            durationMilliseconds: ReasoningLoop<ClockType>.durationMilliseconds(
                                since: startedAt, now: clock.now),
                            at: Date()
                        ))
                } catch {
                    throw RequestFailure(
                        error: .persistenceFailure(
                            "Could not record failed model request: \(error). Original failure: \(requestError)"),
                        state: state)
                }
                throw RequestFailure(error: requestError, state: state)
            }
        }

        private func started(
            _ requestID: ModelRequestID, model: String, kind: ModelRequestKind, contentHashes: [String]?
        ) async throws(AgentRuntimeError) {
            try await emit(
                .modelRequestStarted(
                    ModelRequestRecord(
                        id: requestID,
                        turnID: turnID,
                        model: model,
                        kind: kind,
                        startedAt: Date(),
                        contentHashes: contentHashes
                    )
                )
            )
        }
    }

    init(
        agentID: AgentID,
        turnID: TurnID = TurnID(),
        logger: Logger = Logger(label: "hail.reasoning-loop"),
        authority: any Authority,
        context: @escaping @Sendable () async throws(AgentRuntimeError) -> TurnContext,
        rebuildContext:
            @escaping @Sendable (TurnContext) async throws(AgentRuntimeError) -> TurnContext,
        endpoint: @escaping @Sendable (TurnContext) async throws(AgentRuntimeError) -> ModelEndpoint,
        modelReasoningPolicy: @escaping ModelReasoningPolicy = { _ in .providerDefault },
        session: @escaping @Sendable (AgentTurnContext) async throws(AgentRuntimeError) -> AgentSession,
        keepSession: @escaping @Sendable (consuming AgentSession) async -> Void = { _ in },
        emit: @escaping @Sendable (AgentEvent) async throws(AgentRuntimeError) -> Void,
        recordActivity: @escaping @Sendable (AgentActivity) async -> Void,
        compactor: (any ContextCompactor)? = nil,
        compactionOperation: CompactionOperation? = nil,
        assemblePrompt: @escaping PromptAssembler = assembleStandardPrompt,
        clock: ClockType,
        maxToolRounds: Int
    ) {
        self.agentID = agentID
        self.turnID = turnID
        self.logger = logger
        self.authority = authority
        self.context = context
        self.rebuildContext = rebuildContext
        self.endpoint = endpoint
        self.keepSession = keepSession
        self.modelReasoningPolicy = modelReasoningPolicy
        self.session = session
        self.emit = emit
        self.recordActivity = recordActivity
        self.compactor = compactor
        self.compactionOperation = compactionOperation
        self.assemblePrompt = assemblePrompt
        self.clock = clock
        self.maxToolRounds = maxToolRounds
    }

    /// After a turn: compacts the history when the context the last request reported is past the
    /// threshold, so the next turn starts with room, and nobody waits for it. A compaction that
    /// fails leaves the history as it was; a turn that overflows recovers on its own.
    func compactAfterTurn() async {
        do {
            let turnContext = try await context()
            _ = try await compactIfNeeded(turnContext: turnContext, endpoint: try await endpoint(turnContext))
        } catch {
            logger.warning(
                "Compaction after a turn failed",
                metadata: ["agentID": .string(agentID.rawValue), "error": .string(String(describing: error))])
        }
    }

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection. A failure is
    /// broadcast as ``AgentRunEvent/runFailed(error:at:)`` before it is
    /// rethrown, so consumers always see a terminal update.
    func run<Input: Codable & Sendable, Output>(
        _ input: Input,
        opening: TurnOpening,
        through connection: AgentConnection<Output>
    ) async throws(ReasoningLoopError) {
        do {
            guard maxToolRounds > 0 else {
                throw AgentRuntimeError.configurationError(
                    "maxToolRounds must be positive"
                )
            }
            try await runStreamingTurn(
                input: input,
                opening: opening,
                through: connection
            )
        } catch {
            let end = TurnEnd(error)
            let at = Date()
            // The turn closes either way. Only a crash leaves a turn open, to be finished after it.
            do {
                try await emit(.history(end.event(at: at)))
            } catch {
                let persistenceError = AgentRuntimeError.persistenceFailure(
                    "Could not record how the turn ended: \(error). It ended with: \(end.error)"
                )
                await broadcast(.runFailed(error: persistenceError, at: at), to: connection)
                throw .failureNotEmitted(persistenceError)
            }
            await broadcast(.runFailed(error: end.error, at: at), to: connection)
            throw .failed(end.error)
        }
    }

    private static func checkCancellation() throws(AgentRuntimeError) {
        guard !Task.isCancelled else { throw .cancelled }
    }

    // MARK: - Compaction

    /// The provider-reported occupancy floor for a threshold decision when
    /// no preflight token counter exists. Returns nil when there is no
    /// report, when the report's window does not match the endpoint's
    /// effective window, or when it reports no usage: in every such case the
    /// floor is not trustworthy evidence. The count is used only as the
    /// trigger measurement; the compactor's own threshold still decides.
    static func reportedFloorMeasurement(
        usage: ContextUsage?,
        window: Int
    ) -> RequestMeasurement? {
        guard let usage, usage.limitTokens == window, usage.usedTokens > 0 else {
            return nil
        }
        return RequestMeasurement(tokenCount: usage.usedTokens, source: .reported)
    }

    /// Offers the turn's context to the compactor and journals the result.
    ///
    /// A failure during a `.threshold` pass is
    /// logged and the turn continues un-compacted: the threshold predicts the
    /// request will soon exhaust the window, it does not know the request is
    /// already over, and the provider remains the authority on overflow — its
    /// report starts the `.contextLengthExceeded` recovery pass, whose
    /// failures still propagate because there the request is known not to
    /// fit. A successful compaction is journaled as one atomic
    /// `.history(.compacted)` event and the event-sourced part of this turn
    /// is rebuilt so it already sees the trimmed window. External context
    /// inputs remain those captured for the turn. Internal (not private) for
    /// direct testing.
    func compactIfNeeded(
        turnContext: TurnContext,
        endpoint: any ModelEndpoint,
        arrivals: [Arrival] = [],
        tools: [ToolDefinition] = [],
        trigger: ContextCompactionTrigger = .threshold
    ) async throws(AgentRuntimeError) -> TurnContext {
        let turnContext = turnContext
        guard let compactor else {
            return turnContext
        }

        // Resolve the model capability before entering the pure compaction
        // policy. A normal threshold decision requires a count for this
        // exact request. The generic estimator is not interchangeable with
        // the provider's rendered prompt, so it is reserved for fitting a
        // recovery candidate after an explicit provider overflow. A
        // supported counter that fails is an operation failure, not absence
        // of the capability, and therefore propagates.
        let request = turnContext.preparedRequest.receiving(arrivals).offering(tools)
        guard let contextWindow = endpoint.effectiveContextWindow else {
            throw AgentRuntimeError.configurationError(
                "No context window is configured for model \(endpoint.model); "
                    + "context compaction requires an explicit model capability."
            )
        }
        let budget = try CompactionBudget(contextWindow: contextWindow)
        let measuring: RequestMeasuring
        switch endpoint.tokenCounting {
        case .unavailable:
            // A missing preflight counter is not evidence that the threshold
            // has been crossed. In particular, the generic estimator counts
            // Hail's serialized transcript and tool schemas, while Ollama
            // counts its own rendered chat template; using that estimate here
            // can compact a request that is nowhere near the provider limit.
            // Provider-reported occupancy is different in kind: as a
            // history goes on, the next request strictly grows on the previous
            // one, so the last report is a guaranteed floor, never a stale
            // guess. When a floor exists it is offered as the trigger
            // measurement and the compactor's own threshold still decides;
            // candidate fitting stays on the estimator, with the
            // post-generation guard and the typed overflow recovery as nets.
            // A provider-reported overflow remains an explicit recovery
            // trigger either way.
            if trigger == .contextLengthExceeded {
                measuring = .estimated
            } else if let floor = Self.reportedFloorMeasurement(
                usage: turnContext.latestContextUsage,
                window: contextWindow
            ) {
                measuring = .reportedFloor(floor)
            } else {
                return turnContext
            }
        case .available(let count):
            measuring = .counted(
                RequestMeasurement(tokenCount: try await count(request.entries, request.tools), source: .reported),
                by: { (candidate: PreparedRequest) async throws(AgentRuntimeError) -> RequestMeasurement in
                    do {
                        return RequestMeasurement(
                            tokenCount: try await count(candidate.entries, candidate.tools),
                            source: .reported
                        )
                    } catch is CancellationError {
                        throw AgentRuntimeError.cancelled
                    } catch let error as AgentRuntimeError {
                        throw error
                    } catch {
                        throw AgentRuntimeError.infrastructureFailure(
                            "Token counting failed: \(error)"
                        )
                    }
                })
        }
        let operation = compactionOperation
        let summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> GeneratedContent = {
            request in
            if let operation {
                return try await self.summarize(
                    request: request,
                    endpoint: endpoint,
                    operation: operation
                )
            }
            return try await self.summarize(
                entries: request.entries,
                maxOutputTokens: request.maxOutputTokens,
                endpoint: endpoint
            )
        }
        let contextProjection:
            @Sendable (GeneratedContent, ContextProjectionBudget) throws(AgentRuntimeError) ->
                GeneratedContent =
                    if let operation {
                        operation.contextProjection
                    } else {
                        { @Sendable value, _ in value.generatedContent }
                    }
        let decision: CompactionDecision<GeneratedContent>
        do {
            decision = try await compactor.compact(
                context: turnContext.promptContext,
                request: request,
                budget: budget,
                measuring: measuring,
                assemble: assemblePrompt,
                summarize: summarize,
                contextProjection: contextProjection,
                trigger: trigger
            )
        } catch {
            if case .contextLengthExceeded = trigger {
                throw error
            }
            logger.warning(
                "Context compaction failed; continuing without compacting",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
            return turnContext
        }
        guard case .compacted(let result) = decision else { return turnContext }
        await recordActivity(
            .turn(.progress(.status(GeneratedContent("Compacting conversation context."))), at: Date()))
        await recordActivity(
            .turn(
                .progress(
                    .compaction(
                        output: result.output.generatedContent,
                        context: result.context
                    )
                ),
                at: Date()
            )
        )
        try await emit(
            .history(
                .compacted(
                    AgentHistory.Summary(context: result.context, report: result.output.generatedContent),
                    through: result.through,
                    kept: result.kept)))
        var rebuilt = try await rebuildContext(turnContext)
        // The floor described the pre-compaction occupancy; keeping it would
        // re-trigger compaction on the next check.
        rebuilt.latestContextUsage = nil
        return rebuilt
    }

    /// Runs the summarization prompt through the turn's own endpoint as a
    /// tool-less typed generation request. The compaction value remains
    /// ``GeneratedContent`` at Hail's persistence boundary, preserving
    /// structured output without prescribing product-specific fields.
    private func summarize(
        entries: [Transcript.Entry],
        maxOutputTokens: Int,
        endpoint: any ModelEndpoint
    ) async throws(AgentRuntimeError) -> GeneratedContent {
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let generation = try await Self.value(
            of: try await runner.run(
                model: endpoint.model,
                kind: .compaction,
                contentHashes: RequestContentHash.chain(tools: [], messages: entries),
                stream: endpoint.stream(
                    request: ModelRequest(
                        input: CompactionSummaryRequest(
                            entries: entries,
                            maxOutputTokens: maxOutputTokens
                        ),
                        entries: entries
                    ),
                    tools: [],
                    authority: authority,
                    generating: GeneratedContent.self,
                    purpose: .compaction(maxOutputTokens: maxOutputTokens)
                ),
                from: Generation<GeneratedContent>.pending,
                reduce: Self.generating
            ))
        guard case .generated(let summary) = generation else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced an empty summary")
        }
        return summary
    }

    private func summarize(
        request: CompactionSummaryRequest,
        endpoint: any ModelEndpoint,
        operation: CompactionOperation
    ) async throws(AgentRuntimeError) -> GeneratedContent {
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let generation = try await Self.value(
            of: try await runner.run(
                model: endpoint.model,
                kind: .compaction,
                contentHashes: RequestContentHash.chain(tools: [], messages: request.entries),
                stream: operation.stream(endpoint, request, authority),
                from: Generation<GeneratedContent>.pending,
                reduce: Self.generating
            ))
        guard case .generated(let report) = generation else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced an empty report")
        }
        return report
    }

    /// A request's value, or its failure's error.
    private static func value<State>(
        of request: @autoclosure () async throws(RequestFailure<State>) -> State
    ) async throws(AgentRuntimeError) -> State {
        do {
            return try await request()
        } catch {
            throw error.error
        }
    }

    /// A tool-less request's events, as its value: the generated one, or the failure.
    private static func generating(
        _ generation: Generation<GeneratedContent>, _ event: ModelEvent<GeneratedContent>
    ) throws(AgentRuntimeError) -> Generation<GeneratedContent> {
        switch event {
        case .generated(let value): .generated(value)
        case .failed(let error): throw map(modelError: error)
        default: generation
        }
    }

    // MARK: - Turn execution

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection.
    private func runStreamingTurn<Input: Codable & Sendable, Output>(
        input: Input,
        opening: TurnOpening,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) {
        if case .received(let received) = opening {
            try await emit(.history(.received(received, turn: turnID)))
        }
        await broadcast(.received(opening.input, at: Date()), to: connection)
        await broadcast(.runStarted(agentID: agentID, at: Date()), to: connection)

        // The input timestamp remains part of the journaled message. It is
        // metadata for the host and tools, not another model instruction.
        // Current time and calendar interpretation belong to explicit tools.
        let turnStartedAt = clock.now

        // Per-turn wall-clock timing, logged on every exit path (success,
        // failure, cancellation) so slow turns are visible in the logs.
        defer {
            logger.info(
                "Turn ended",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "durationMs": .string(
                        "\(Self.durationMilliseconds(since: turnStartedAt, now: clock.now))"),
                ]
            )
        }

        var turnContext = try await context()
        let endpoint = try await self.endpoint(turnContext)

        // The input was journaled before `context()` ran, so the assembled
        // prompt already contains it. The request holds only what happened:
        // where things are now is reached through the tools the session
        // offers, never written in as a message nobody sent.
        // The turn runs in the agent's session, where the last turn left off: each call still open
        // shows where it is, or finishes, before the model does anything. The session goes back to
        // the agent when the turn ends, however it ends.
        let outcome: Output = try await withSession(
            AgentTurnContext(
                agentID: agentID,
                turnID: turnID,
                input: opening.input
            )
        ) { (session: inout AgentSession) async throws(AgentRuntimeError) -> Output in
            // What arrived since the last turn: calls that finished meanwhile.
            let arrivals = await session.begin(turnID)
            let modelTools = session.allTools()
            // Budget the request that will actually be sent, not a second
            // approximation assembled from AgentState fields. This includes the
            // tool schemas as well as assembled prompt output.
            let schemas = session.schemas()
            var promptMetadata: [String: Logger.MetadataValue] = [
                "agentID": .string(agentID.rawValue),
                "historyEntries": .string("\(turnContext.preparedRequest.entries.count)"),
                "arrivals": .string("\(arrivals.count)"),
                "toolCount": .string("\(schemas.count)"),
                "contextWindow": .string("\(endpoint.effectiveContextWindow ?? 0)"),
            ]
            if case .available(let count) = endpoint.tokenCounting {
                promptMetadata["historyTokens"] = .string(
                    "\(try await count(turnContext.preparedRequest.entries, []))"
                )
                promptMetadata["toolSchemaTokens"] = .string("\(try await count([], schemas))")
            } else {
                promptMetadata["tokenCounts"] = .string("unavailable")
            }
            logger.info("Prompt composition", metadata: promptMetadata)
            let turn = TurnRequest(
                value: input, request: turnContext.preparedRequest.receiving(arrivals).offering(schemas))
            return try await runTurn(
                input: turn,
                arrivals: arrivals,
                schemas: schemas,
                modelTools: modelTools,
                turnSnapshot: turnContext,
                session: &session,
                endpoint: endpoint,
                calls: TurnCalls(limit: maxToolRounds, count: opening.callsMade),
                through: connection
            )
        }

        let timestamp = Date()
        try await emit(.history(.replied(AgentHistory.Reply(content: outcome.generatedContent, at: timestamp))))
        await broadcast(.responseRecorded(content: outcome, at: timestamp), to: connection)
        await broadcast(.runCompleted(at: Date()), to: connection)
    }

    /// Runs `body` in the agent's session: taken for the turn, and given back when the turn ends,
    /// however it ends.
    private func withSession<Result>(
        _ turn: AgentTurnContext,
        _ body: (inout AgentSession) async throws(AgentRuntimeError) -> Result
    ) async throws(AgentRuntimeError) -> Result {
        var session = try await self.session(turn)
        let result: Result
        do {
            result = try await body(&session)
        } catch {
            await keepSession(session)
            throw error
        }
        await keepSession(session)
        return result
    }

    /// The turn: one request, run in the agent's session, which runs each tool call the model
    /// makes and answers it. A request that overflows the model's context is asked again,
    /// compacted, a bounded number of times.
    private func runTurn<Input: Sendable, Output>(
        input: TurnRequest<Input>,
        arrivals: [Arrival],
        schemas: [ToolDefinition],
        modelTools: [AnyTool],
        turnSnapshot: TurnContext,
        session: inout AgentSession,
        endpoint: ModelEndpoint,
        calls: TurnCalls,
        contextRecoveryAttempts: Int = 0,
        noticesGiven: Int = 0,
        answersAskedAgainForTheirForm: Int = 0,
        thinking: ModelReasoningOverride? = nil,
        callsRanOut: Bool = false,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> Output
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        try Self.checkCancellation()
        switch try await requestTurn(
            input: input,
            schemas: schemas,
            modelTools: modelTools,
            session: &session,
            endpoint: endpoint,
            calls: calls,
            thinking: thinking,
            through: connection
        ) {
        case .generated(let output):
            return output
        case .ranOut(let calls):
            // Told so, journaled, and asked again from the journal, without thinking: the tools
            // it called have answered, and aren't run again. A few times, then it's said why.
            guard noticesGiven < Self.mostNoticesOfAnAnswerRunningOut else {
                throw AgentRuntimeError.modelThoughtPastAnswer
            }
            try await emit(.history(.noticed(.answerRanOut, at: Date())))
            let rebuilt = try await rebuildContext(turnSnapshot)
            let schemas = session.schemas()
            return try await runTurn(
                input: TurnRequest(
                    value: input.value, request: rebuilt.preparedRequest.receiving(arrivals).offering(schemas)),
                arrivals: arrivals,
                schemas: schemas,
                modelTools: session.allTools(),
                turnSnapshot: turnSnapshot,
                session: &session,
                endpoint: endpoint,
                calls: calls,
                contextRecoveryAttempts: contextRecoveryAttempts,
                noticesGiven: noticesGiven + 1,
                answersAskedAgainForTheirForm: answersAskedAgainForTheirForm,
                thinking: .disabled,
                callsRanOut: callsRanOut,
                through: connection
            )
        case .outOfShape(let calls, let written):
            // Told so, with what it wrote, journaled, and asked again from the journal: the tools
            // it called have answered, and aren't run again. A few times, then it's said why.
            guard answersAskedAgainForTheirForm < Self.mostAnswersAskedAgainForTheirForm else {
                throw AgentRuntimeError.modelAnswerOutOfShape(written: written)
            }
            try await emit(.history(.noticed(.answerOutOfShape(written: written), at: Date())))
            let rebuilt = try await rebuildContext(turnSnapshot)
            let schemas = callsRanOut ? [] : session.schemas()
            return try await runTurn(
                input: TurnRequest(
                    value: input.value, request: rebuilt.preparedRequest.receiving(arrivals).offering(schemas)),
                arrivals: arrivals,
                schemas: schemas,
                modelTools: callsRanOut ? [] : session.allTools(),
                turnSnapshot: turnSnapshot,
                session: &session,
                endpoint: endpoint,
                calls: calls,
                contextRecoveryAttempts: contextRecoveryAttempts,
                noticesGiven: noticesGiven,
                answersAskedAgainForTheirForm: answersAskedAgainForTheirForm + 1,
                thinking: thinking,
                callsRanOut: callsRanOut,
                through: connection
            )
        case .outOfCalls(let calls):
            // Told so, journaled, and asked once more from the journal, offered no tools: the
            // calls it made have answered, and it says where the work stands.
            guard !callsRanOut else { throw AgentRuntimeError.toolCallsRanOut(limit: calls.limit) }
            try await emit(.history(.noticed(.toolCallsRanOut(limit: calls.limit), at: Date())))
            let rebuilt = try await rebuildContext(turnSnapshot)
            return try await runTurn(
                input: TurnRequest(
                    value: input.value, request: rebuilt.preparedRequest.receiving(arrivals).offering([])),
                arrivals: arrivals,
                schemas: [],
                modelTools: [],
                turnSnapshot: turnSnapshot,
                session: &session,
                endpoint: endpoint,
                calls: calls,
                contextRecoveryAttempts: contextRecoveryAttempts,
                noticesGiven: noticesGiven,
                answersAskedAgainForTheirForm: answersAskedAgainForTheirForm,
                thinking: thinking,
                callsRanOut: true,
                through: connection
            )
        case .overflowed(let calls):
            guard contextRecoveryAttempts < 3 else {
                throw AgentRuntimeError.contextLengthExceeded
            }
            // The turn's work so far is folded into the summary; its open tabs offer what they
            // offer now, unless the turn has made all its calls.
            let schemas = callsRanOut ? [] : session.schemas()
            let modelTools = callsRanOut ? [] : session.allTools()
            let compactedInput = try await recoverFromContextOverflow(
                input: input,
                arrivals: arrivals,
                schemas: schemas,
                turnSnapshot: turnSnapshot,
                endpoint: endpoint
            )
            return try await runTurn(
                input: compactedInput,
                arrivals: arrivals,
                schemas: schemas,
                modelTools: modelTools,
                turnSnapshot: turnSnapshot,
                session: &session,
                endpoint: endpoint,
                calls: calls,
                contextRecoveryAttempts: contextRecoveryAttempts + 1,
                noticesGiven: noticesGiven,
                answersAskedAgainForTheirForm: answersAskedAgainForTheirForm,
                thinking: thinking,
                callsRanOut: callsRanOut,
                through: connection
            )
        }
    }

    /// How many times a turn's model is told its answer ran out, and asked again.
    static var mostNoticesOfAnAnswerRunningOut: Int { 2 }

    /// How many times a turn's model is asked again for an answer in the form asked for: a model
    /// that misses the form with the notice right before it won't keep to it on another try.
    static var mostAnswersAskedAgainForTheirForm: Int { 1 }

    /// A provider is the authority on whether a request actually fits. The
    /// normal compaction pass is intentionally conservative and may not know
    /// the cost of a binary artifact, so a provider-reported overflow gets a
    /// bounded recovery pass with an explicit trigger.
    private func recoverFromContextOverflow<Input: Sendable>(
        input: TurnRequest<Input>,
        arrivals: [Arrival],
        schemas: [ToolDefinition],
        turnSnapshot: TurnContext,
        endpoint: ModelEndpoint
    ) async throws(AgentRuntimeError) -> TurnRequest<Input> {
        guard compactor != nil else {
            throw AgentRuntimeError.contextLengthExceeded
        }

        let rebuilt = try await rebuildContext(turnSnapshot)
        let prepared = try await compactIfNeeded(
            turnContext: rebuilt,
            endpoint: endpoint,
            arrivals: arrivals,
            tools: schemas,
            trigger: .contextLengthExceeded
        )
        guard prepared.promptContext.history != rebuilt.promptContext.history else {
            throw AgentRuntimeError.contextLengthExceeded
        }
        // Compaction folded the open turn's work so far into the summary; the turn's input stays,
        // so the request still answers it.
        return TurnRequest(
            value: input.value,
            request: prepared.preparedRequest.receiving(arrivals).offering(schemas))
    }

    /// The turn's request, in the agent's session: streamed once, start to end. Each tool call the
    /// model makes is run by the session as it comes, and answered, and the model goes on in the
    /// same request; the generated value ends it.
    private func requestTurn<Input: Sendable, Output>(
        input: TurnRequest<Input>,
        schemas: [ToolDefinition],
        modelTools: [AnyTool],
        session: inout AgentSession,
        endpoint: ModelEndpoint,
        calls: TurnCalls,
        thinking: ModelReasoningOverride? = nil,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> TurnRequestOutcome<Output>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let stream: AsyncStream<ModelEvent<Output>>
        let request = ModelRequest(
            input: input.value,
            entries: input.request.entries,
            reasoning: thinking
                ?? modelReasoningPolicy(
                    ModelReasoningContext(
                        model: endpoint.model,
                        purpose: .generation,
                        hasTools: !modelTools.isEmpty,
                        completedToolRounds: calls.count
                    )
                ),
            toolCallsLeft: calls.limit - calls.count
        )
        stream = endpoint.stream(
            request: request,
            tools: modelTools,
            authority: authority,
            generating: Output.self,
            purpose: .generation
        )

        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let progress: TurnProgress<Output>
        do {
            progress = try await runner.run(
                model: endpoint.model,
                kind: .generation,
                contentHashes: RequestContentHash.chain(
                    tools: schemas,
                    messages: input.request.entries
                ),
                stream: stream,
                from: TurnProgress(calls: calls, generation: .pending)
            ) { (progress: TurnProgress<Output>, event: ModelEvent<Output>) async throws(AgentRuntimeError) in
                for update in TurnReducer.reduce(event: event, at: Date()) {
                    await broadcast(update, to: connection)
                }
                switch event {
                case .partialUpdated(let content):
                    await recordActivity(.turn(.progress(.partial(content)), at: Date()))
                case .activity(.reasoningDelta(let fragment)):
                    await recordActivity(.turn(.progress(.reasoning(fragment)), at: Date()))
                case .activity(.status(let message)):
                    await recordActivity(.turn(.progress(.status(message)), at: Date()))
                case .toolCall(let toolCall):
                    await recordActivity(.turn(.progress(.toolCalled(toolCall.call)), at: Date()))
                    let ran = try await runToolCall(
                        toolCall.call, calls: progress.calls, in: &session, through: connection)
                    toolCall.reply.give(ran.answer)
                    return TurnProgress(calls: ran.calls, generation: progress.generation)
                case .generated(let value):
                    return TurnProgress(calls: progress.calls, generation: .generated(value))
                case .usage, .contextUsage:
                    break
                case .failed(let modelError):
                    throw Self.map(modelError: modelError)
                }
                return progress
            }
        } catch {
            // The calls made before an overflow, or before an answer ran out, still count.
            if error.error == .modelThoughtPastAnswer, error.state.calls.count > calls.count {
                return .ranOut(error.state.calls)
            }
            if case .toolCallsRanOut = error.error { return .outOfCalls(error.state.calls) }
            if case .modelAnswerOutOfShape(let written) = error.error {
                return .outOfShape(error.state.calls, written: written)
            }
            guard error.error == .contextLengthExceeded else { throw error.error }
            return .overflowed(error.state.calls)
        }

        guard case .generated(let generated) = progress.generation else {
            throw AgentRuntimeError.modelMisbehavior("Model request ended without a generated output")
        }
        return .generated(generated)
    }

    /// Runs one tool call the model made, in the session: journaled before it runs, so replay
    /// observes the same interaction, then its result. Gives the answer, with the tools the
    /// session offers now, and the turn's calls after it.
    private func runToolCall<Output>(
        _ call: ToolCall,
        calls: TurnCalls,
        in session: inout AgentSession,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> (answer: ToolAnswer, calls: TurnCalls)
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let calling = try calls.calling()
        try await emit(.history(.called(call, at: Date())))

        let startedAt = clock.now
        let execution = try await session.execute(call)
        try Self.checkCancellation()
        logger.info(
            "Tool call finished",
            metadata: [
                "agentID": .string(agentID.rawValue),
                "tool": .string(call.name),
                "durationMs": .string("\(Self.durationMilliseconds(since: startedAt, now: clock.now))"),
            ]
        )
        let result = execution.result
        try await emit(.history(.resulted(result, at: Date())))
        await recordActivity(.turn(.progress(.toolFinished(result)), at: Date()))
        await broadcast(.toolCompleted(result: result, at: Date()), to: connection)

        return (
            ToolAnswer(result: result, page: execution.page, tools: session.allTools()), try calling.resulted(result)
        )
    }

    // MARK: - Updates

    private func broadcast<Output>(
        _ update: AgentRunEvent<Output>,
        to connection: AgentConnection<Output>
    ) async
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        do {
            log(update: update)
            try await connection.broadcast(update)
        } catch {
            logger.debug(
                "Agent update consumer failed",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
        }
    }

    private func log<Output>(update: AgentRunEvent<Output>)
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let metadata: Logger.Metadata = ["agentID": .string(agentID.rawValue)]
        switch update {
        case .modelOutputGenerated(_, _):
            logger.debug("Agent forwarding typed model output", metadata: metadata)
        case .toolRequested(let toolCall, _):
            logger.info(
                "Agent forwarding tool request",
                metadata: metadata.merging(
                    ["tool": .string(toolCall.name)], uniquingKeysWith: { _, new in new })
            )
        case .toolCompleted(let result, _):
            logger.info(
                "Agent forwarding tool completion",
                metadata: metadata.merging(
                    ["tool": .string(result.name)], uniquingKeysWith: { _, new in new })
            )
        default:
            logger.debug(
                "Agent forwarding update",
                metadata: metadata.merging(
                    ["update": .string(String(describing: update))], uniquingKeysWith: { _, new in new })
            )
        }
    }

    private static func map(modelError: ModelEndpointError) -> AgentRuntimeError {
        switch modelError {
        case .configuration(let reason):
            return .configurationError(reason)
        case .authentication:
            return .configurationError("authentication failed")
        case .unavailable:
            return .modelUnavailable
        case .rateLimit:
            return .rateLimit
        case .contextLengthExceeded:
            return .contextLengthExceeded
        case .invalidRequest(let reason):
            return .modelMisbehavior("invalid request: \(reason)")
        case .requestFailed(let reason):
            return .modelRequestFailed(HailErrorFormatter.sanitizedModelOutput(reason))
        case .invalidResponse(let reason):
            return .modelMisbehavior("invalid response: \(reason)")
        case .decodingError(let underlying):
            return .modelMisbehavior("decoding error: \(underlying)")
        case .thoughtPastAnswer:
            return .modelThoughtPastAnswer
        case .answerOutOfShape(let written):
            return .modelAnswerOutOfShape(written: written)
        case .cancelled:
            return .cancelled
        }
    }

    private static func mapRequestError(_ error: any Error) -> AgentRuntimeError {
        if error is CancellationError {
            return .cancelled
        }
        if let runtimeError = error as? AgentRuntimeError {
            return runtimeError
        }
        if let modelError = error as? ModelEndpointError {
            return map(modelError: modelError)
        }
        return .infrastructureFailure(String(describing: error))
    }

    private static func durationMilliseconds(since start: ClockType.Instant, now: ClockType.Instant)
        -> Int
    {
        let components = start.duration(to: now).components
        let milliseconds =
            components.seconds.multipliedReportingOverflow(by: 1_000).partialValue
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }
}
