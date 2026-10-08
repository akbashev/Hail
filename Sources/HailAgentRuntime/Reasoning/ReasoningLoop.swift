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

/// The only two valid outcomes of one successful model request. Tool calls
/// are work for the next transition; a generated value completes the turn.
/// An empty stream and undecodable text are errors, not extra enum cases.
private enum ModelRoundOutcome<Output> {
    case completed(Output)
    case requiresTools(ModelToolRound)
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

    func recording(results: [ToolResult]) -> (tracker: Self, repeated: Bool) {
        let failure = ToolFailureSignature(results: results)
        guard !failure.isEmpty else {
            return (Self(), false)
        }

        let nextRepetitions: Int
        if failure == lastFailure {
            nextRepetitions = repetitions + 1
        } else {
            nextRepetitions = 1
        }
        return (
            Self(lastFailure: failure, repetitions: nextRepetitions),
            nextRepetitions >= Self.maximumRepetitions
        )
    }
}

/// Pure accumulation for one provider request. Provider activity is handled
/// separately; this value contains only the information needed to decide the
/// request's terminal domain outcome.
private struct ModelRoundAccumulator<Output>: Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
    let requestedTools: ModelToolRound?
    let generated: Output?

    init(
        requestedTools: ModelToolRound? = nil,
        generated: Output? = nil
    ) {
        self.requestedTools = requestedTools
        self.generated = generated
    }

    func applying(_ event: ModelEvent<Output>) -> Self {
        switch event {
        case .toolsRequested(let round):
            return Self(requestedTools: round, generated: generated)
        case .generated(let value):
            return Self(requestedTools: requestedTools, generated: value)
        default:
            return self
        }
    }

    var outcome: ModelRoundOutcome<Output>? {
        if let requestedTools { return .requiresTools(requestedTools) }
        if let generated { return .completed(generated) }
        return nil
    }
}

private struct ToolRoundResult<Input: Sendable> {
    let input: TurnPrompt<Input>
    let results: [ToolResult]
}

/// Pure transcript transition for one model-requested tool round. Journaling,
/// authorization, execution, and compaction happen after this value is built.
private struct ToolRoundPlan<Input: Sendable> {
    let input: TurnPrompt<Input>
    let calls: [ToolCall]
}

private enum ReasoningLoopPlanning {
    static func toolRound<Input: Sendable>(
        input: TurnPrompt<Input>,
        round: ModelToolRound
    ) -> ToolRoundPlan<Input> {
        var nextInput = input.appendingReasoning(round)
        let responseSegments = round.narration?.segments ?? []
        if !responseSegments.isEmpty {
            nextInput = nextInput.appending(
                .response(
                    .init(
                        assetIDs: round.narration?.assetIDs ?? [],
                        segments: responseSegments
                    )
                )
            )
        }
        if !round.calls.isEmpty {
            nextInput = nextInput.appending(.toolCalls(.init(round.calls.map(transcriptToolCall))))
        }
        return ToolRoundPlan(input: nextInput, calls: round.calls)
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
/// ``AgentRunEvent`` values. Narration (status/thinking/text/tool) is
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

        case .toolsRequested(let round):
            return round.calls.map { .toolRequested(toolCall: $0, at: timestamp) }

        case .generated(let value):
            return [.modelOutputGenerated(content: value, at: timestamp)]

        case .partialUpdated(let partial):
            return [.modelOutputPartialUpdated(content: partial, at: timestamp)]

        case .usage, .contextUsage:
            return []

        case .failed:
            return []
        }
    }
}

// MARK: - ReasoningLoop

/// The assembled context for one turn, plus the session metadata the
/// session-owning endpoint path needs and the stable identity fingerprint
/// (invalidates stale sessions).
struct TurnContext: Sendable {
    /// The policy-owned request. Messages are always derived from this value,
    /// so prompt assembly and compaction cannot drift apart.
    var preparedRequest: PreparedRequest
    var entries: [Transcript.Entry] { preparedRequest.entries }
    /// The derived turn context from which the request was assembled; handed
    /// to the compactor independently from request accounting.
    let promptContext: PromptContext
    let sessionIdentity: SessionIdentity
    /// The journaled harness session (id + identity) from previous runs, used
    /// to resume after a restart and to detect when the id changes.
    let modelSession: ModelSessionResume?
    /// Occupancy the provider reported for the most recent request. The next
    /// request strictly grows on it, so it is a floor for threshold decisions
    /// when no preflight token counter exists. Consumed (cleared) once
    /// compaction acts on it.
    var latestContextUsage: ContextUsage? = nil
}

/// The prompt for one live reasoning turn.
///
/// The event-sourced transcript is the history. Reference data, the current
/// input, and outputs produced while this turn is running are the current
/// prompt. Keeping those parts separate prevents request-local data from
/// being inserted into the durable history by array surgery.
struct TurnHistory: Sendable {
    let entries: [Transcript.Entry]
}

struct TurnInput<Input: Sendable>: Sendable {
    /// The original request value remains available for the whole turn. The
    /// transcript entries are the model-facing projection supplied by the
    /// caller; Hail does not ask `Input` to manufacture one.
    let value: Input
    let entries: [Transcript.Entry]
    let currentEntry: Transcript.Entry?
}

struct TurnPrompt<Input: Sendable>: Sendable {
    let history: TurnHistory
    let current: TurnInput<Input>
    let reasoningRounds: [[Transcript.Segment]]
    private let currentSourceIndex: Int?

    var entries: [Transcript.Entry] {
        history.entries + current.entries
    }

    init(
        input: Input,
        reference: [Transcript.Entry],
        currentEntry: Transcript.Entry?,
        currentSourceIndex: Int? = nil,
        currentIndex: Int? = nil,
        reasoningRounds: [[Transcript.Segment]] = [],
        in entries: [Transcript.Entry]
    ) {
        self.currentSourceIndex = currentSourceIndex
        self.reasoningRounds = reasoningRounds

        guard let currentEntry,
            let currentIndex = currentIndex ?? entries.lastIndex(of: currentEntry)
        else {
            self.history = TurnHistory(entries: entries)
            self.current = TurnInput(
                value: input,
                entries: reference + [currentEntry].compactMap { $0 },
                currentEntry: currentEntry
            )
            return
        }

        self.history = TurnHistory(entries: Array(entries[..<currentIndex]))
        self.current = TurnInput(
            value: input,
            entries: reference
                + [currentEntry]
                + Array(entries[(currentIndex + 1)...]),
            currentEntry: currentEntry
        )
    }

    private init(
        history: TurnHistory,
        current: TurnInput<Input>,
        currentSourceIndex: Int?,
        reasoningRounds: [[Transcript.Segment]]
    ) {
        self.history = history
        self.current = current
        self.currentSourceIndex = currentSourceIndex
        self.reasoningRounds = reasoningRounds
    }

    func appending(_ entry: Transcript.Entry) -> Self {
        return Self(
            history: history,
            current: TurnInput(
                value: current.value,
                entries: current.entries + [entry],
                currentEntry: current.currentEntry
            ),
            currentSourceIndex: currentSourceIndex,
            reasoningRounds: reasoningRounds
        )
    }

    func appendingToolOutput(
        callID: String,
        name: String,
        output: ToolOutput,
        superseding superseded: [String] = []
    ) -> Self {
        let entry = Transcript.Entry.toolOutput(
            .init(id: callID, toolName: name, segments: transcriptSegments(output))
        )
        // A scope's earlier page is replaced by a line, the way a browser shows only the current
        // page: the model reads one current state, not every one before it.
        let entries = current.entries.map { entry -> Transcript.Entry in
            guard case .toolOutput(let earlier) = entry, superseded.contains(earlier.id) else { return entry }
            return .toolOutput(
                .init(
                    id: earlier.id, toolName: earlier.toolName,
                    segments: [.text(.init(content: "(Replaced by a later page of the same call.)"))]))
        }
        return Self(
            history: history,
            current: TurnInput(
                value: current.value,
                entries: entries + [entry],
                currentEntry: current.currentEntry
            ),
            currentSourceIndex: currentSourceIndex,
            reasoningRounds: reasoningRounds
        )
    }

    func appendingReasoning(_ round: ModelToolRound) -> Self {
        var reasoning = reasoningRounds
        reasoning.append(round.reasoning)
        return Self(
            history: history,
            current: current,
            currentSourceIndex: currentSourceIndex,
            reasoningRounds: reasoning
        )
    }

    /// Keeps the live prompt intact while replacing only its durable history
    /// after context compaction or provider-overflow recovery.
    func rebased(on entries: [Transcript.Entry]) -> Self {
        let retainedReasoning = reasoningRounds(for: entries)
        guard let currentEntry = current.currentEntry,
            let currentIndex = entries.lastIndex(of: currentEntry)
        else {
            return Self(
                history: TurnHistory(entries: entries),
                current: current,
                currentSourceIndex: currentSourceIndex,
                reasoningRounds: retainedReasoning
            )
        }
        return Self(
            history: TurnHistory(entries: Array(entries[..<currentIndex])),
            current: current,
            currentSourceIndex: currentSourceIndex,
            reasoningRounds: retainedReasoning
        )
    }

    func rebased(on request: PreparedRequest) -> Self {
        let retainedReasoning = reasoningRounds(for: request.entries)
        guard let currentSourceIndex,
            let currentIndex = request.messageIndex(forSourceIndex: currentSourceIndex)
        else {
            return rebased(on: request.entries)
        }
        return Self(
            history: TurnHistory(entries: Array(request.entries[..<currentIndex])),
            current: current,
            currentSourceIndex: currentSourceIndex,
            reasoningRounds: retainedReasoning
        )
    }

    private func reasoningRounds(
        for entries: [Transcript.Entry]
    ) -> [[Transcript.Segment]] {
        var assistantToolRoundCount = 0
        for index in entries.indices.dropLast() {
            if case .response = entries[index],
                case .toolCalls = entries[index + 1]
            {
                assistantToolRoundCount += 1
            }
        }
        guard assistantToolRoundCount < reasoningRounds.count else {
            return reasoningRounds
        }
        return Array(reasoningRounds.suffix(assistantToolRoundCount))
    }
}

private func reasoningRounds(
    in messages: [ChatMessage]
) -> [[Transcript.Segment]] {
    messages.reduce(into: []) { result, message in
        guard case .assistantToolCall(let round, _) = message else { return }
        // Keep empty rounds in the sequence: Ollama's request encoder counts
        // every assistant response/tool-call pair, so later reasoning must
        // stay aligned even when an earlier provider round had no reasoning.
        result.append(round.reasoning)
    }
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
    /// agent's default). Handed to session-owning endpoints alongside the
    /// ``TurnDelta`` so the harness's own effects (fs/terminal delegation,
    /// process spawns) are checked against the same lane as the tool registry.
    let authority: any Authority

    /// Builds the prompt context (system prompt, memory, conversation thread,
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

    /// Optional context compactor, consulted before each request for
    /// non-session-owning endpoints. See ``ContextCompactor``.
    let compactor: (any ContextCompactor)?

    /// The host may provide one typed report operation whose context projection
    /// is persisted by Hail. This keeps auxiliary product data in the same
    /// compaction request instead of launching a second model request.
    let compactionOperation: CompactionOperation?

    /// The host's pure prompt assembler. Compaction uses it to validate a
    /// candidate summary against the request that would actually be sent.
    let assemblePrompt: PromptAssembler

    /// Resolves the tool registry available to this turn.
    let tools: @Sendable (AgentTurnContext) async throws(AgentRuntimeError) -> AgentScope
    /// Gives the agent's scope back when the turn ends, with the scopes still open in it.
    let keepScopes: @Sendable (consuming AgentScope) async -> Void

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
    struct ModelRequestRunner: Sendable {
        let turnID: TurnID
        let emit: @Sendable (AgentEvent) async throws(AgentRuntimeError) -> Void
        let recordActivity: @Sendable (AgentActivity) async -> Void
        let clock: ClockType

        func run<Output>(
            model: String,
            kind: ModelRequestKind,
            contentHashes: [String]? = nil,
            stream: AsyncStream<ModelEvent<Output>>,
            handle: (ModelEvent<Output>) async throws(AgentRuntimeError) -> Void
        ) async throws(AgentRuntimeError) -> ModelUsage?
        where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
            let requestID = ModelRequestID()
            let startedAt = clock.now
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
                    try await handle(event)
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
                return usage
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
                    throw AgentRuntimeError.persistenceFailure(
                        "Could not record failed model request: \(error). Original failure: \(requestError)"
                    )
                }
                throw requestError
            }
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
        tools: @escaping @Sendable (AgentTurnContext) async throws(AgentRuntimeError) -> AgentScope,
        keepScopes: @escaping @Sendable (consuming AgentScope) async -> Void = { _ in },
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
        self.keepScopes = keepScopes
        self.modelReasoningPolicy = modelReasoningPolicy
        self.tools = tools
        self.emit = emit
        self.recordActivity = recordActivity
        self.compactor = compactor
        self.compactionOperation = compactionOperation
        self.assemblePrompt = assemblePrompt
        self.clock = clock
        self.maxToolRounds = maxToolRounds
    }

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection. A failure is
    /// broadcast as ``AgentRunEvent/runFailed(error:at:)`` before it is
    /// rethrown, so consumers always see a terminal update.
    func run<Input: Codable & Sendable, Output>(
        _ input: Input,
        message: ChatMessage,
        referenceEntries: [Transcript.Entry],
        inputID: String?,
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
                message: message,
                referenceEntries: referenceEntries,
                inputID: inputID,
                through: connection
            )
        } catch {
            let (runtimeError, emitsFailure) = Self.mapTurnError(error)
            let at = Date()
            if emitsFailure {
                // Emit the failure so it survives reloads; the turn bracket
                // is closed by the caller (`turnCompleted`), so no re-run
                // triggers. Cancellation bypasses this: an abandoned turn is
                // not a failure and must not replay as one.
                do {
                    try await emit(.turnFailed(error: runtimeError, at: at))
                } catch {
                    let persistenceError = AgentRuntimeError.persistenceFailure(
                        "Could not record turn failure: \(error). Original failure: \(runtimeError)"
                    )
                    await broadcast(.runFailed(error: persistenceError, at: at), to: connection)
                    throw .failureNotEmitted(persistenceError)
                }
            }
            await broadcast(.runFailed(error: runtimeError, at: at), to: connection)
            throw .failed(runtimeError)
        }
    }

    /// Normalizes the existential `catch` boundary around the typed turn.
    /// Swift exposes a caught value as `any Error` even when every current
    /// dependency throws `AgentRuntimeError`; keeping this conversion in one
    /// place prevents a future untyped dependency from leaking out.
    /// It also decides whether the error is emitted as
    /// ``AgentEvent/turnFailed(error:at:)``.
    /// Cancellation — a raw `CancellationError` from a consumer abort, or an
    /// endpoint reporting `.cancelled` — is the caller abandoning the turn,
    /// not a failure: emitting it would replay as a failed turn after
    /// re-activation, so it bypasses the event stream.
    static func mapTurnError(_ error: any Error) -> (mapped: AgentRuntimeError, emitsFailure: Bool) {
        if error is CancellationError {
            return (.cancelled, false)
        }
        if let runtimeError = error as? AgentRuntimeError {
            return (runtimeError, runtimeError != .cancelled)
        }
        return (.infrastructureFailure(String(describing: error)), true)
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
    /// Session-owning harnesses manage their own context server-side and are
    /// never offered compaction. A failure during a `.threshold` pass is
    /// logged and the turn continues un-compacted: the threshold predicts the
    /// request will soon exhaust the window, it does not know the request is
    /// already over, and the provider remains the authority on overflow — its
    /// report starts the `.contextLengthExceeded` recovery pass, whose
    /// failures still propagate because there the request is known not to
    /// fit. A successful compaction is journaled as one atomic
    /// `conversationCompacted` event and the event-sourced part of this turn
    /// is rebuilt so it already sees the trimmed window. External context
    /// inputs remain those captured for the turn. Internal (not private) for
    /// direct testing.
    func compactIfNeeded(
        turnContext: TurnContext,
        endpoint: any ModelEndpoint,
        additionalEntries: [Transcript.Entry] = [],
        tools: [ToolDefinition] = [],
        trigger: ContextCompactionTrigger = .threshold
    ) async throws(AgentRuntimeError) -> TurnContext {
        let turnContext = turnContext
        let implementsSessionContract = endpoint is SessionOwningEndpoint
        guard
            (endpoint.contextOwnership == .endpointSession) == implementsSessionContract
        else {
            throw AgentRuntimeError.configurationError(
                "Model endpoint \(endpoint.model) declares \(endpoint.contextOwnership) context ownership "
                    + "but its SessionOwningEndpoint conformance does not match"
            )
        }
        guard let compactor, endpoint.contextOwnership == .runtime else {
            return turnContext
        }

        // Resolve the model capability before entering the pure compaction
        // policy. A normal threshold decision requires a count for this
        // exact request. The generic estimator is not interchangeable with
        // the provider's rendered prompt, so it is reserved for fitting a
        // recovery candidate after an explicit provider overflow. A
        // supported counter that fails is an operation failure, not absence
        // of the capability, and therefore propagates.
        let request = turnContext.preparedRequest.appending(
            suffix: additionalEntries,
            tools: tools
        )
        guard let contextWindow = endpoint.effectiveContextWindow else {
            throw AgentRuntimeError.configurationError(
                "No context window is configured for model \(endpoint.model); "
                    + "context compaction requires an explicit model capability."
            )
        }
        let budget = try CompactionBudget(contextWindow: contextWindow)
        let measurement: RequestMeasurement?
        let measure: RequestMeasurer?
        switch endpoint.tokenCounting {
        case .unavailable:
            // A missing preflight counter is not evidence that the threshold
            // has been crossed. In particular, the generic estimator counts
            // Hail's serialized transcript and tool schemas, while Ollama
            // counts its own rendered chat template; using that estimate here
            // can compact a request that is nowhere near the provider limit.
            // Provider-reported occupancy is different in kind: within a
            // conversation the next request strictly grows on the previous
            // one, so the last report is a guaranteed floor, never a stale
            // guess. When a floor exists it is offered as the trigger
            // measurement and the compactor's own threshold still decides;
            // candidate fitting stays on the estimator, with the
            // post-generation guard and the typed overflow recovery as nets.
            // A provider-reported overflow remains an explicit recovery
            // trigger either way.
            if trigger == .contextLengthExceeded {
                measurement = nil
                measure = nil
            } else if let floor = Self.reportedFloorMeasurement(
                usage: turnContext.latestContextUsage,
                window: contextWindow
            ) {
                measurement = floor
                measure = nil
            } else {
                return turnContext
            }
        case .available(let count):
            measurement = RequestMeasurement(
                tokenCount: try await count(request.entries, request.tools),
                source: .reported
            )
            measure = {
                (candidate: PreparedRequest) async throws(AgentRuntimeError) -> RequestMeasurement in
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
            }
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
                measurement: measurement,
                measure: measure,
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
            .conversationCompacted(
                archivedCount: result.archivedCount,
                content: result.context,
                output: result.output.generatedContent
            )
        )
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
        var generated: GeneratedContent?
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let handle: (ModelEvent<GeneratedContent>) async throws(AgentRuntimeError) -> Void = { event in
            switch event {
            case .generated(let value):
                generated = value
            case .failed(let error):
                throw Self.map(modelError: error)
            default:
                break
            }
        }
        _ = try await runner.run(
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
            handle: handle
        )
        guard let generated else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced an empty summary")
        }
        return generated
    }

    private func summarize(
        request: CompactionSummaryRequest,
        endpoint: any ModelEndpoint,
        operation: CompactionOperation
    ) async throws(AgentRuntimeError) -> GeneratedContent {
        var generated: GeneratedContent?
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let handle: (ModelEvent<GeneratedContent>) async throws(AgentRuntimeError) -> Void = { event in
            switch event {
            case .generated(let value):
                generated = value
            case .failed(let error):
                throw Self.map(modelError: error)
            default:
                break
            }
        }
        _ = try await runner.run(
            model: endpoint.model,
            kind: .compaction,
            contentHashes: RequestContentHash.chain(tools: [], messages: request.entries),
            stream: operation.stream(endpoint, request, authority),
            handle: handle
        )
        guard let generated else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced an empty report")
        }
        return generated
    }

    // MARK: - Turn execution

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection.
    private func runStreamingTurn<Input: Codable & Sendable, Output>(
        input: Input,
        message: ChatMessage,
        referenceEntries: [Transcript.Entry],
        inputID: String?,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) {
        try await emit(.messageReceived(message))
        await broadcast(.messageHandled(message: message, at: Date()), to: connection)
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
        // prompt already contains it. Request-local context is deliberately
        // kept out of the system role. Ollama collates all system messages at
        // the front of its request; putting changing data there invalidates
        // the reusable prefix on every turn. The context is placed immediately
        // before the current input instead, so it cannot be mistaken for the
        // user's latest request.
        var turnContextEntries = referenceEntries

        let inputEntries = modelEntries(from: message, context: turnContext.promptContext)
        guard let inputEntry = inputEntries.last else {
            throw AgentRuntimeError.modelMisbehavior(
                "The turn message has no model-facing transcript entry."
            )
        }
        // The turn runs in the agent's scope, where the last turn left off: each call still open
        // shows where it is, or finishes, before the model does anything. When the turn ends, the scope goes
        // back to the agent with what's still open; only a cancelled turn ends it.
        var registry = try await tools(
            AgentTurnContext(
                agentID: agentID,
                turnID: turnID,
                message: message,
                inputID: inputID
            )
        )
        for page in await registry.begin(turnID) {
            turnContextEntries.append(
                .prompt(.init(segments: [.text(.init(content: page.output.textRepresentation))])))
        }
        let modelTools = registry.allTools()
        // Budget the request that will actually be sent, not a second
        // approximation assembled from AgentState fields. This includes the
        // per-turn delta and tool schemas as well as assembled prompt output.
        let schemas = registry.schemas()
        var promptMetadata: [String: Logger.MetadataValue] = [
            "agentID": .string(agentID.rawValue),
            "historyEntries": .string("\(turnContext.preparedRequest.entries.count)"),
            "referenceEntries": .string("\(turnContextEntries.count)"),
            "toolCount": .string("\(schemas.count)"),
            "contextWindow": .string("\(endpoint.effectiveContextWindow ?? 0)"),
        ]
        if case .available(let count) = endpoint.tokenCounting {
            promptMetadata["historyTokens"] = .string(
                "\(try await count(turnContext.preparedRequest.entries, []))"
            )
            promptMetadata["referenceTokens"] = .string(
                "\(try await count(turnContextEntries, []))"
            )
            promptMetadata["toolSchemaTokens"] = .string("\(try await count([], schemas))")
        } else {
            promptMetadata["tokenCounts"] = .string("unavailable")
        }
        logger.info("Prompt composition", metadata: promptMetadata)
        turnContext = try await compactIfNeeded(
            turnContext: turnContext,
            endpoint: endpoint,
            additionalEntries: turnContextEntries,
            tools: schemas
        )
        let currentSourceIndex = turnContext.promptContext.conversationThread.indices.last
        let currentIndex = currentSourceIndex.flatMap {
            turnContext.preparedRequest.messageIndex(forSourceIndex: $0)
        }
        let currentEntry =
            currentIndex.flatMap { index in
                turnContext.preparedRequest.entries.indices.contains(index)
                    ? turnContext.preparedRequest.entries[index]
                    : nil
            } ?? inputEntry
        let prompt = TurnPrompt(
            input: input,
            reference: turnContextEntries,
            currentEntry: currentEntry,
            currentSourceIndex: currentSourceIndex,
            currentIndex: currentIndex,
            reasoningRounds: reasoningRounds(
                in: turnContext.promptContext.conversationThread
            ),
            in: turnContext.entries
        )

        let delta = TurnDelta(
            currentEntries: prompt.current.entries,
            sessionIdentity: turnContext.sessionIdentity
        )

        let outcome: Output
        do {
            outcome = try await runTurn(
                input: prompt,
                delta: delta,
                turnContextEntries: turnContextEntries,
                schemas: schemas,
                modelTools: modelTools,
                turnSnapshot: turnContext,
                registry: &registry,
                endpoint: endpoint,
                through: connection
            )
        } catch {
            // Scopes outlive turns: a turn ending, however it ends, leaves them as they are.
            await keepScopes(registry)
            throw error
        }
        await keepScopes(registry)

        // Persist the harness session id (and its identity fingerprint) so a
        // restart can resume the CLI session instead of bootstrapping from
        // the journal.
        if let sessionEndpoint = endpoint as? SessionOwningEndpoint,
            let sessionID = await sessionEndpoint.currentSessionID,
            sessionID != turnContext.modelSession?.id
        {
            try await emit(
                .modelSessionIdentified(id: sessionID, identity: turnContext.sessionIdentity)
            )
        }

        let timestamp = Date()
        try await emit(
            .responseReceived(
                sender: agentID.rawValue,
                content: outcome.generatedContent,
                at: timestamp
            )
        )
        await broadcast(.responseRecorded(content: outcome, at: timestamp), to: connection)
        await broadcast(.runCompleted(at: Date()), to: connection)
    }

    /// Advances the turn through a bounded sequence of model/tool transitions.
    /// Messages are passed as values between rounds, so the control flow does
    /// not rely on a mutable `while true` loop or an optional success sentinel.

    private func runTurn<Input: Sendable, Output>(
        input: TurnPrompt<Input>,
        delta: TurnDelta,
        turnContextEntries: [Transcript.Entry],
        schemas: [ToolDefinition],
        modelTools: [AnyTool],
        turnSnapshot: TurnContext,
        registry: inout AgentScope,
        endpoint: ModelEndpoint,
        completedToolRounds: Int = 0,
        lastToolRound: ToolRoundOutcome? = nil,
        contextRecoveryAttempts: Int = 0,
        toolFailureTracker: ToolFailureTracker = .init(),
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> Output
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        try Self.checkCancellation()
        let round: ModelRoundOutcome<Output>
        do {
            round = try await requestModelRound(
                input: input,
                delta: delta,
                schemas: schemas,
                modelTools: modelTools,
                endpoint: endpoint,
                lastToolRound: lastToolRound,
                through: connection
            )
        } catch AgentRuntimeError.contextLengthExceeded {
            guard contextRecoveryAttempts < 3 else {
                throw AgentRuntimeError.contextLengthExceeded
            }

            let compactedInput = try await recoverFromContextOverflow(
                input: input,
                turnContextEntries: turnContextEntries,
                schemas: schemas,
                turnSnapshot: turnSnapshot,
                endpoint: endpoint
            )
            return try await runTurn(
                input: compactedInput,
                delta: delta,
                turnContextEntries: turnContextEntries,
                schemas: schemas,
                modelTools: modelTools,
                turnSnapshot: turnSnapshot,
                registry: &registry,
                endpoint: endpoint,
                completedToolRounds: completedToolRounds,
                lastToolRound: lastToolRound,
                contextRecoveryAttempts: contextRecoveryAttempts + 1,
                toolFailureTracker: toolFailureTracker,
                through: connection
            )
        }

        switch round {
        case .completed(let output):
            return output

        case .requiresTools(let round):
            // Reject excess work before journaling or executing its effects.
            guard completedToolRounds < maxToolRounds else {
                throw AgentRuntimeError.modelMisbehavior(
                    "Model exceeded the maximum of \(maxToolRounds) tool rounds in a single turn."
                )
            }
            let next = try await executeToolRound(
                round: round,
                schemas: schemas,
                input: input,
                turnContextEntries: turnContextEntries,
                turnSnapshot: turnSnapshot,
                registry: &registry,
                endpoint: endpoint,
                through: connection
            )
            let failureTracking = toolFailureTracker.recording(results: next.results)
            if failureTracking.repeated {
                let failure = next.results.first { result in
                    result.failureKind == .invalidArguments
                        || result.failureKind == .rejected
                }
                throw AgentRuntimeError.toolFailed(
                    name: failure?.name ?? round.calls.first?.name ?? "unknown",
                    reason:
                        "The model repeated the same failed tool call twice. \(failure?.output.textRepresentation ?? "Tool execution failed.")"
                )
            }
            return try await runTurn(
                input: next.input,
                delta: delta,
                turnContextEntries: turnContextEntries,
                schemas: registry.schemas(),
                modelTools: registry.allTools(),
                turnSnapshot: turnSnapshot,
                registry: &registry,
                endpoint: endpoint,
                completedToolRounds: completedToolRounds + 1,
                lastToolRound: next.results.contains(where: \.isError) ? .failed : .succeeded,
                contextRecoveryAttempts: contextRecoveryAttempts,
                toolFailureTracker: failureTracking.tracker,
                through: connection
            )
        }
    }

    /// A provider is the authority on whether a request actually fits. The
    /// normal compaction pass is intentionally conservative and may not know
    /// the cost of a binary artifact, so a provider-reported overflow gets a
    /// bounded recovery pass with an explicit trigger.
    private func recoverFromContextOverflow<Input: Sendable>(
        input: TurnPrompt<Input>,
        turnContextEntries: [Transcript.Entry],
        schemas: [ToolDefinition],
        turnSnapshot: TurnContext,
        endpoint: ModelEndpoint
    ) async throws(AgentRuntimeError) -> TurnPrompt<Input> {
        guard endpoint.contextOwnership == .runtime, compactor != nil else {
            throw AgentRuntimeError.contextLengthExceeded
        }

        let rebuilt = try await rebuildContext(turnSnapshot)
        let prepared = try await compactIfNeeded(
            turnContext: rebuilt,
            endpoint: endpoint,
            additionalEntries: turnContextEntries,
            tools: schemas,
            trigger: .contextLengthExceeded
        )
        let wasCompacted =
            prepared.promptContext.contextSummary != rebuilt.promptContext.contextSummary
            || prepared.promptContext.conversationThread.count
                != rebuilt.promptContext.conversationThread.count
        guard wasCompacted else {
            throw AgentRuntimeError.contextLengthExceeded
        }
        return input.rebased(on: prepared.preparedRequest)
    }

    /// Executes one provider request and closes its raw stream into a valid
    /// domain outcome. This is the imperative shell around the pure outcome
    /// distinction above.
    private func requestModelRound<Input: Sendable, Output>(
        input: TurnPrompt<Input>,
        delta: TurnDelta,
        schemas: [ToolDefinition],
        modelTools: [AnyTool],
        endpoint: ModelEndpoint,
        lastToolRound: ToolRoundOutcome?,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> ModelRoundOutcome<Output>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let stream: AsyncStream<ModelEvent<Output>>
        let request = ModelRequest(
            input: input.current.value,
            entries: input.entries,
            reasoningRounds: input.reasoningRounds,
            reasoning: modelReasoningPolicy(
                ModelReasoningContext(
                    model: endpoint.model,
                    purpose: .generation,
                    hasTools: !modelTools.isEmpty,
                    completedToolRounds: input.reasoningRounds.count,
                    lastToolRound: lastToolRound
                )
            )
        )
        if let sessionEndpoint = endpoint as? SessionOwningEndpoint {
            stream = sessionEndpoint.stream(
                request: request,
                delta: delta,
                authority: authority,
                tools: modelTools,
                generating: Output.self,
                purpose: .generation
            )
        } else {
            stream = endpoint.stream(
                request: request,
                tools: modelTools,
                authority: authority,
                generating: Output.self,
                purpose: .generation
            )
        }

        var accumulator = ModelRoundAccumulator<Output>()
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        let handle: (ModelEvent<Output>) async throws(AgentRuntimeError) -> Void = { event in
            let updates = TurnReducer.reduce(
                event: event,
                at: Date()
            )
            for update in updates {
                await broadcast(update, to: connection)
            }

            switch event {
            case .activity(.narrationDelta(let fragment)):
                await recordActivity(.turn(.progress(.narration(fragment)), at: Date()))
            case .activity(.reasoningDelta(let fragment)):
                await recordActivity(.turn(.progress(.reasoning(fragment)), at: Date()))
            case .activity(.status(let message)):
                await recordActivity(.turn(.progress(.status(message)), at: Date()))
            case .toolsRequested(let round):
                accumulator = accumulator.applying(event)
                for call in round.calls {
                    await recordActivity(.turn(.progress(.toolCalled(call)), at: Date()))
                }
            case .generated:
                accumulator = accumulator.applying(event)
            case .partialUpdated, .usage, .contextUsage:
                break
            case .failed(let modelError):
                throw Self.map(modelError: modelError)
            }
        }
        _ = try await runner.run(
            model: endpoint.model,
            kind: .generation,
            contentHashes: RequestContentHash.chain(
                tools: schemas,
                messages: input.entries
            ),
            stream: stream,
            handle: handle
        )

        if let outcome = accumulator.outcome {
            return outcome
        }
        throw AgentRuntimeError.modelMisbehavior(
            "Model request ended without a generated output or tool calls"
        )
    }

    /// Applies one tool transition and returns the value passed to the next
    /// model round. Journaling precedes execution so replay observes the same
    /// semantic interaction.
    private func executeToolRound<Input: Sendable, Output>(
        round: ModelToolRound,
        schemas: [ToolDefinition],
        input: TurnPrompt<Input>,
        turnContextEntries: [Transcript.Entry],
        turnSnapshot: TurnContext,
        registry: inout AgentScope,
        endpoint: ModelEndpoint,
        through connection: AgentConnection<Output>
    ) async throws(AgentRuntimeError) -> ToolRoundResult<Input>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let plan = ReasoningLoopPlanning.toolRound(input: input, round: round)
        var nextInput = plan.input

        try await emit(
            .assistantToolRound(
                round: round,
                at: Date()
            )
        )

        let startedAt = clock.now
        let executions = try await registry.executeWithOutputs(plan.calls)
        try Self.checkCancellation()
        logger.info(
            "Tool round finished",
            metadata: [
                "agentID": .string(agentID.rawValue),
                "tools": .string(round.calls.map(\.name).joined(separator: ",")),
                "durationMs": .string("\(Self.durationMilliseconds(since: startedAt, now: clock.now))"),
            ]
        )
        for execution in executions {
            let result = execution.result
            nextInput = nextInput.appendingToolOutput(
                callID: result.toolCallID,
                name: result.name,
                output: result.output,
                superseding: execution.superseded
            )
            try await emit(.toolResult(result, at: Date()))
            await recordActivity(.turn(.progress(.toolFinished(result)), at: Date()))
            await broadcast(
                .toolCompleted(result: result, at: Date()),
                to: connection
            )
        }

        guard endpoint.contextOwnership == .runtime, compactor != nil else {
            return ToolRoundResult(
                input: nextInput,
                results: executions.map(\.result)
            )
        }

        let rebuilt = try await rebuildContext(turnSnapshot)
        let prepared = try await compactIfNeeded(
            turnContext: rebuilt,
            endpoint: endpoint,
            additionalEntries: turnContextEntries,
            tools: schemas
        )
        let wasCompacted =
            prepared.promptContext.contextSummary != rebuilt.promptContext.contextSummary
            || prepared.promptContext.conversationThread.count
                != rebuilt.promptContext.conversationThread.count
        guard wasCompacted else {
            return ToolRoundResult(
                input: nextInput,
                results: executions.map(\.result)
            )
        }
        return ToolRoundResult(
            input: nextInput.rebased(on: prepared.preparedRequest),
            results: executions.map(\.result)
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
