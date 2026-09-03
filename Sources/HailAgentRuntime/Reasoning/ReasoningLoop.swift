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

// MARK: - Turn state machine

/// Pure state machine that turns a stream of ``ModelEvent`` values into a
/// stream of ``AgentUpdate`` values. It exists so the reasoning loop can stay
/// declarative: one transition function decides what to emit, and the caller
/// only handles side effects.
private enum TurnState {
    case idle
    case text(String)
    case thinking(String)
}

/// The only two valid outcomes of one successful model request. Tool calls
/// are work for the next transition; a generated value completes the turn.
/// An empty stream and undecodable text are errors, not extra enum cases.
private enum ModelRoundOutcome<Output> {
    case completed(Output)
    case requiresTools(narration: String, calls: [ToolCall], schemas: [LLMToolSchema])
}

/// Signals that the turn's terminal failure could not be journaled. The host
/// must not append `turnCompleted`, so replay can recognize and recover the
/// unmatched turn.
struct UnjournaledTurnFailure: Error {
    let runtimeError: AgentRuntimeError
}

/// Pure reducer that turns a stream of ``ModelEvent`` values into the typed
/// run events of an ``AgentUpdate``. Narration (status/thinking/text/tool) is
/// recorded on the activity stream by the loop; only control and the typed
/// outcome are emitted here.
private enum TurnReducer {
    static func reduce<Output: Codable & Sendable>(
        state: TurnState,
        event: ModelEvent<Output>,
        at timestamp: Date
    ) -> (TurnState, [AgentUpdate<Output>]) {
        switch (state, event) {
        case (.text(let current), .text(let fragment)):
            return (.text(current + fragment), [])
        case (_, .text(let fragment)):
            return (.text(fragment), [])

        case (.thinking(let current), .thinking(let text)):
            return (.thinking(current + text), [])
        case (_, .thinking(let text)):
            return (.thinking(text), [])

        case (_, .status):
            return (state, [])

        case (_, .toolCall(let call)):
            return (.idle, [.run(.event(.toolRequested(toolCall: call, at: timestamp)))])

        case (_, .generated(let value)):
            if Output.self != String.self {
                return (.idle, [.run(.event(.modelOutputGenerated(content: value, at: timestamp)))])
            }
            return (.idle, [])

        case (_, .partialUpdated):
            return (.idle, [])

        case (_, .usage), (_, .contextUsage):
            return (state, [])

        case (_, .failed):
            return (.idle, [])
        }
    }
}

// MARK: - ReasoningLoop

/// The assembled context for one turn, plus the session metadata the
/// session-owning endpoint path needs: the working-memory snapshot (rides the
/// warm delta) and the stable identity fingerprint (invalidates stale
/// sessions).
struct TurnContext: Sendable {
    /// The policy-owned request. Messages are always derived from this value,
    /// so prompt assembly and compaction cannot drift apart.
    var preparedRequest: PreparedRequest
    var messages: [LLMMessage] { preparedRequest.messages }
    /// The inputs the messages were assembled from; handed to the
    /// ``ContextCompactor`` so it can estimate and select from the same data.
    var promptContext: PromptContext
    var workingMemory: [String]
    var sessionIdentity: SessionIdentity
    /// The journaled harness session (id + identity) from previous runs, used
    /// to resume after a restart and to detect when the id changes.
    var modelSessionID: SessionID?
    var modelSessionIdentity: SessionIdentity?
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
    let context: @Sendable () async throws -> TurnContext

    /// Resolves the model endpoint for this turn.
    let endpoint: @Sendable () async throws -> ModelEndpoint

    /// Optional context compactor, consulted before each request for
    /// non-session-owning endpoints. See ``ContextCompactor``.
    let compactor: (any ContextCompactor)?

    /// Resolves the tool registry available to this turn.
    let tools: @Sendable () async throws -> ToolRegistry

    /// Journals a persistent agent event.
    let emit: @Sendable (AgentEvent) async throws -> Void

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
        let emit: @Sendable (AgentEvent) async throws -> Void
        let recordActivity: @Sendable (AgentActivity) async -> Void
        let clock: ClockType

        func run<Output: AgentOutput>(
            model: String,
            kind: ModelRequestKind,
            stream: AsyncStream<ModelEvent<Output>>,
            handle: (ModelEvent<Output>) async throws -> Void
        ) async throws -> ModelUsage? {
            let requestID = ModelRequestID()
            let startedAt = clock.now
            try await emit(
                .modelRequestStarted(
                    ModelRequestRecord(
                        id: requestID,
                        turnID: turnID,
                        model: model,
                        kind: kind,
                        startedAt: Date()
                    )))

            var usage: ModelUsage?
            do {
                for await event in stream {
                    try Task.checkCancellation()
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
                try Task.checkCancellation()
                try await emit(
                    .modelRequestCompleted(
                        id: requestID,
                        usage: usage,
                        durationMilliseconds: ReasoningLoop<ClockType>.durationMilliseconds(
                            since: startedAt, now: clock.now),
                        at: Date()
                    ))
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
        context: @escaping @Sendable () async throws -> TurnContext,
        endpoint: @escaping @Sendable () async throws -> ModelEndpoint,
        tools: @escaping @Sendable () async throws -> ToolRegistry,
        emit: @escaping @Sendable (AgentEvent) async throws -> Void,
        recordActivity: @escaping @Sendable (AgentActivity) async -> Void,
        compactor: (any ContextCompactor)? = nil,
        clock: ClockType,
        maxToolRounds: Int = 25
    ) {
        self.agentID = agentID
        self.turnID = turnID
        self.logger = logger
        self.authority = authority
        self.context = context
        self.endpoint = endpoint
        self.tools = tools
        self.emit = emit
        self.recordActivity = recordActivity
        self.compactor = compactor
        self.clock = clock
        self.maxToolRounds = maxToolRounds
        precondition(maxToolRounds > 0, "maxToolRounds must be positive")
    }

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection. A failure is
    /// broadcast as ``AgentRunEvent/runFailed(error:at:)`` before it is
    /// rethrown, so consumers always see a terminal update.
    func run<Input: AgentInput, Output: AgentOutput>(
        _ input: Input,
        through connection: AgentConnection<Output>
    ) async throws {
        do {
            try await runStreamingTurn(input: input, through: connection)
        } catch {
            let (runtimeError, journalsFailure) = Self.mapTurnError(error)
            let at = Date()
            if journalsFailure {
                // Journal the failure so it survives reloads; the turn bracket
                // is closed by the caller (`turnCompleted`), so no re-run
                // triggers. Cancellation bypasses this: an abandoned turn is
                // not a failure and must not replay as one.
                do {
                    try await emit(.turnFailed(error: runtimeError, at: at))
                } catch {
                    let persistenceError = AgentRuntimeError.persistenceFailure(
                        "Could not record turn failure: \(error). Original failure: \(runtimeError)"
                    )
                    await broadcast(
                        .run(.event(.runFailed(error: persistenceError, at: at))),
                        to: connection
                    )
                    throw UnjournaledTurnFailure(runtimeError: persistenceError)
                }
            }
            await broadcast(.run(.event(.runFailed(error: runtimeError, at: at))), to: connection)
            throw runtimeError
        }
    }

    /// Maps an error escaping the turn to the runtime error that is thrown,
    /// and decides whether it is journaled as ``AgentEvent/turnFailed(error:at:)``.
    /// Cancellation — a raw `CancellationError` from a consumer abort, or an
    /// endpoint reporting `.cancelled` — is the caller abandoning the turn,
    /// not a failure: journaling it would replay as a failed turn after
    /// re-activation, so it bypasses the journal.
    static func mapTurnError(_ error: any Error) -> (mapped: AgentRuntimeError, journalsFailure: Bool) {
        if error is CancellationError {
            return (.cancelled, false)
        }
        if let runtimeError = error as? AgentRuntimeError {
            return (runtimeError, runtimeError != .cancelled)
        }
        return (.modelMisbehavior(String(describing: error)), true)
    }

    // MARK: - Compaction

    /// Offers the turn's context to the compactor and journals the result.
    ///
    /// Session-owning harnesses manage their own context server-side and are
    /// never offered compaction. Compactor and summarizer failures propagate:
    /// sending the known-oversized request would hide the actual failure and
    /// violate the budget decision. A successful compaction is journaled as
    /// one atomic `conversationCompacted` event and the context is rebuilt so
    /// this turn already sees the trimmed window. Internal (not private) for
    /// direct testing.
    func compactIfNeeded(
        turnContext: TurnContext,
        endpoint: any ModelEndpoint,
        additionalMessages: [LLMMessage] = [],
        tools: [LLMToolSchema] = []
    ) async throws -> TurnContext {
        var turnContext = turnContext
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

        // Let the endpoint provide the effective request window and a
        // model-aware count when it owns a compatible tokenizer/template. A
        // missing measurement falls back to the compactor's conservative
        // estimator. A supported counter that fails is an operation failure,
        // not absence of the capability, and therefore propagates.
        let request = turnContext.preparedRequest.appending(
            suffix: additionalMessages,
            tools: tools
        )
        let projectedTokenCount: Int?
        switch endpoint.tokenCounting {
        case .unavailable:
            projectedTokenCount = nil
        case .available(let count):
            projectedTokenCount = try await count(
                request.messages,
                request.tools
            )
        }
        turnContext.promptContext = turnContext.promptContext.withMeasurement(
            PromptMeasurement(
                effectiveContextWindow: endpoint.effectiveContextWindow,
                projectedTokenCount: projectedTokenCount,
                tokenCounting: endpoint.tokenCounting
            )
        )
        let decision: CompactionDecision
        do {
            decision = try await compactor.compact(
                context: turnContext.promptContext,
                request: request
            ) { messages in
                try await self.summarize(messages: messages, endpoint: endpoint)
            }
        } catch let modelError as ModelEndpointError {
            throw Self.map(modelError: modelError)
        }
        guard case .compacted(let result) = decision else { return turnContext }
        await recordActivity(.turn(.progress(.status("Compacting conversation context.")), at: Date()))
        try await emit(.conversationCompacted(archivedCount: result.archivedCount, summary: result.summary))
        return try await context()
    }

    /// Runs the summarization prompt through the turn's own endpoint as a
    /// plain (tool-less) chat request and reduces the stream to its text.
    private func summarize(
        messages: [LLMMessage],
        endpoint: any ModelEndpoint
    ) async throws -> String {
        var text = ""
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        _ = try await runner.run(
            model: endpoint.model,
            kind: .compaction,
            stream: endpoint.stream(messages: messages, tools: nil)
        ) { event in
            switch event {
            case .text(let fragment):
                text += fragment
            case .generated(let value):
                if text.isEmpty { text = value }
            case .failed(let error):
                throw error
            default:
                break
            }
        }
        guard !text.isEmpty else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced an empty summary")
        }
        return text
    }

    // MARK: - Turn execution

    /// Runs one full agent turn: builds context, drives the model/tool loop,
    /// journals persistent events, forwards live updates, and broadcasts the
    /// final generated value (if any) through the connection.
    private func runStreamingTurn<Input: AgentInput, Output: AgentOutput>(
        input: Input,
        through connection: AgentConnection<Output>
    ) async throws {
        let message = input.asChatMessage(timestamp: Date())
        try await emit(.messageReceived(message))
        await broadcast(.run(.event(.messageHandled(message: message, at: Date()))), to: connection)
        await broadcast(.run(.event(.runStarted(agentID: agentID, at: Date()))), to: connection)

        // Capture this once and inject it into the model context. The model
        // needs a stable reference for relative dates during a turn; the
        // `now` tool is available when it needs a fresh value later.
        let turnStartedAt = clock.now
        let turnStartedAtDate = Date()

        // Per-turn wall-clock timing, logged on every exit path (success,
        // failure, cancellation) so slow turns are visible in the logs.
        defer {
            logger.info(
                "Turn ended",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "durationMs": .string("\(Self.durationMilliseconds(since: turnStartedAt, now: clock.now))"),
                ]
            )
        }

        let registry = try await tools()
        let endpoint = try await self.endpoint()
        var turnContext = try await context()

        // The input was journaled before `context()` ran, so the assembled
        // prompt already contains it. Keep the per-turn instructions separate:
        // stateless/cold requests append only those instructions, while a warm
        // session receives the instructions plus the input as its delta.
        var turnInstructions: [LLMMessage] = []
        let turnClockInstruction = LLMMessage(
            role: .system,
            content:
                "Turn started at \(turnStartedAtDate.ISO8601Format()). Use this timestamp as the current time at the beginning of the turn."
        )
        turnInstructions.append(turnClockInstruction)

        for instruction in input.systemInstructions() {
            let instructionMessage = LLMMessage(role: .system, content: instruction)
            turnInstructions.append(instructionMessage)
        }

        var deltaMessages = turnInstructions
        switch message {
        case .text(let sender, let content, _):
            let inputMessage = LLMMessage(role: .user, content: content, name: sender)
            deltaMessages.append(inputMessage)
        case .response(let sender, let payload, _):
            let content = modelResponseContent(payload)
            if !content.isEmpty {
                let inputMessage = LLMMessage(
                    role: sender == agentID.rawValue ? .assistant : .user,
                    content: content
                )
                deltaMessages.append(inputMessage)
            }
        case .toolCall(let calls, _):
            let inputMessage = LLMMessage(
                role: .assistant,
                content: "",
                toolCalls: calls.map { LLMToolCall($0) }
            )
            deltaMessages.append(inputMessage)
        case .toolResult(let id, let content, _):
            let inputMessage = LLMMessage(role: .tool, content: content, toolCallID: id)
            deltaMessages.append(inputMessage)
        case .failure:
            // Turn failures are transcript-only; the model never sees them.
            break
        case .decisionRequest, .decisionResolved:
            // Display-only messages; the model learns about resolutions
            // through the ask_user tool result or resume messages.
            break
        }

        // Budget the request that will actually be sent, not a second
        // approximation assembled from AgentState fields. This includes the
        // per-turn delta and tool schemas as well as assembled prompt output.
        let schemas = await registry.schemas()
        turnContext = try await compactIfNeeded(
            turnContext: turnContext,
            endpoint: endpoint,
            additionalMessages: turnInstructions,
            tools: schemas
        )
        var messages = turnContext.messages
        messages.append(contentsOf: turnInstructions)

        let delta = TurnDelta(
            messages: deltaMessages,
            workingMemory: turnContext.workingMemory,
            sessionIdentity: turnContext.sessionIdentity
        )

        let outcome = try await runTurn(
            messages: messages,
            delta: delta,
            turnInstructions: turnInstructions,
            registry: registry,
            endpoint: endpoint,
            through: connection
        )

        // Persist the harness session id (and its identity fingerprint) so a
        // restart can resume the CLI session instead of bootstrapping from
        // the journal.
        if let sessionEndpoint = endpoint as? SessionOwningEndpoint,
            let sessionID = await sessionEndpoint.currentSessionID,
            sessionID != turnContext.modelSessionID
        {
            try await emit(
                .modelSessionIdentified(id: sessionID, identity: turnContext.sessionIdentity)
            )
        }

        let timestamp = Date()
        try await emit(
            .responseReceived(
                sender: agentID.rawValue,
                payload: try JSONEncoder().encode(outcome),
                at: timestamp
            )
        )
        await broadcast(
            .run(.event(.responseRecorded(content: outcome, at: timestamp))), to: connection)
        await broadcast(.run(.event(.runCompleted(at: Date()))), to: connection)
    }

    /// Advances the turn through a bounded sequence of model/tool transitions.
    /// Messages are passed as values between rounds, so the control flow does
    /// not rely on a mutable `while true` loop or an optional success sentinel.
    private func runTurn<Output: AgentOutput>(
        messages: [LLMMessage],
        delta: TurnDelta,
        turnInstructions: [LLMMessage],
        registry: ToolRegistry,
        endpoint: ModelEndpoint,
        completedToolRounds: Int = 0,
        through connection: AgentConnection<Output>
    ) async throws -> Output {
        try Task.checkCancellation()
        switch try await requestModelRound(
            messages: messages,
            delta: delta,
            registry: registry,
            endpoint: endpoint,
            through: connection
        ) {
        case .completed(let output):
            return output

        case .requiresTools(let narration, let calls, let schemas):
            // Reject excess work before journaling or executing its effects.
            guard completedToolRounds < maxToolRounds else {
                throw AgentRuntimeError.modelMisbehavior(
                    "Model exceeded the maximum of \(maxToolRounds) tool rounds in a single turn."
                )
            }
            let nextMessages = try await executeToolRound(
                narration: narration,
                calls: calls,
                schemas: schemas,
                messages: messages,
                turnInstructions: turnInstructions,
                registry: registry,
                endpoint: endpoint,
                through: connection
            )
            return try await runTurn(
                messages: nextMessages,
                delta: delta,
                turnInstructions: turnInstructions,
                registry: registry,
                endpoint: endpoint,
                completedToolRounds: completedToolRounds + 1,
                through: connection
            )
        }
    }

    /// Executes one provider request and closes its raw stream into a valid
    /// domain outcome. This is the imperative shell around the pure outcome
    /// distinction above.
    private func requestModelRound<Output: AgentOutput>(
        messages: [LLMMessage],
        delta: TurnDelta,
        registry: ToolRegistry,
        endpoint: ModelEndpoint,
        through connection: AgentConnection<Output>
    ) async throws -> ModelRoundOutcome<Output> {
        let schemas = await registry.schemas()
        let tools = schemas.isEmpty ? nil : schemas
        let stream: AsyncStream<ModelEvent<Output>>
        if let sessionEndpoint = endpoint as? SessionOwningEndpoint {
            stream = sessionEndpoint.stream(
                messages: messages,
                delta: delta,
                authority: authority,
                tools: tools,
                responseType: Output.self
            )
        } else {
            stream = endpoint.stream(
                messages: messages,
                tools: tools,
                responseType: Output.self
            )
        }

        var turnState = TurnState.idle
        var calls: [ToolCall] = []
        var text = ""
        var thinking = ""
        var generated: Output?
        let runner = ModelRequestRunner(
            turnID: turnID,
            emit: emit,
            recordActivity: recordActivity,
            clock: clock
        )
        _ = try await runner.run(
            model: endpoint.model,
            kind: .generation,
            stream: stream
        ) { event in
            let (nextState, updates) = TurnReducer.reduce(
                state: turnState,
                event: event,
                at: Date()
            )
            turnState = nextState
            for update in updates {
                await broadcast(update, to: connection)
            }

            switch event {
            case .text(let fragment):
                text += fragment
                await recordActivity(.turn(.progress(.text(text)), at: Date()))
            case .thinking(let fragment):
                thinking += fragment
                await recordActivity(.turn(.progress(.reasoning(thinking)), at: Date()))
            case .status(let message):
                await recordActivity(.turn(.progress(.status(message)), at: Date()))
            case .toolCall(let call):
                calls.append(call)
                await recordActivity(.turn(.progress(.tool(name: call.name)), at: Date()))
            case .generated(let value):
                generated = value
            case .partialUpdated, .usage, .contextUsage:
                break
            case .failed(let modelError):
                throw Self.map(modelError: modelError)
            }
        }

        if !calls.isEmpty {
            return .requiresTools(narration: text, calls: calls, schemas: schemas)
        }
        if let generated {
            return .completed(generated)
        }
        guard !text.isEmpty else {
            throw AgentRuntimeError.modelMisbehavior(
                "Model request ended without output or tool calls"
            )
        }
        do {
            return .completed(try Output(GeneratedContent(json: text)))
        } catch {
            throw AgentRuntimeError.modelMisbehavior(
                "Model text did not satisfy the output contract: \(error)"
            )
        }
    }

    /// Applies one tool transition and returns the value passed to the next
    /// model round. Journaling precedes execution so replay observes the same
    /// semantic interaction.
    private func executeToolRound<Output: AgentOutput>(
        narration: String,
        calls: [ToolCall],
        schemas: [LLMToolSchema],
        messages: [LLMMessage],
        turnInstructions: [LLMMessage],
        registry: ToolRegistry,
        endpoint: ModelEndpoint,
        through connection: AgentConnection<Output>
    ) async throws -> [LLMMessage] {
        var nextMessages = messages
        nextMessages.append(
            LLMMessage(
                role: .assistant,
                content: narration,
                toolCalls: calls.map { LLMToolCall($0) }
            )
        )

        if !narration.isEmpty {
            try await emit(.assistantText(content: narration, at: Date()))
        }
        for call in calls {
            try await emit(.toolInvoked(call, at: Date()))
        }

        let startedAt = clock.now
        let results = try await registry.execute(calls)
        try Task.checkCancellation()
        logger.info(
            "Tool round finished",
            metadata: [
                "agentID": .string(agentID.rawValue),
                "tools": .string(calls.map(\.name).joined(separator: ",")),
                "durationMs": .string("\(Self.durationMilliseconds(since: startedAt, now: clock.now))"),
            ]
        )
        for result in results {
            nextMessages.append(
                LLMMessage(
                    role: .tool,
                    content: result.output,
                    toolCallID: result.toolCallID
                )
            )
            try await emit(.toolResult(result, at: Date()))
            await broadcast(
                .run(.event(.toolCompleted(result: result, at: Date()))),
                to: connection
            )
        }

        guard endpoint.contextOwnership == .runtime, compactor != nil else {
            return nextMessages
        }
        let rebuilt = try await context()
        let prepared = try await compactIfNeeded(
            turnContext: rebuilt,
            endpoint: endpoint,
            additionalMessages: turnInstructions,
            tools: schemas
        )
        let wasCompacted =
            prepared.promptContext.contextSummary != rebuilt.promptContext.contextSummary
            || prepared.promptContext.conversationThread.count
                != rebuilt.promptContext.conversationThread.count
        guard wasCompacted else { return nextMessages }
        return prepared.messages + turnInstructions
    }

    // MARK: - Updates

    private func broadcast<Output: AgentOutput>(
        _ update: AgentUpdate<Output>,
        to connection: AgentConnection<Output>
    ) async {
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

    private func log<Output: AgentOutput>(update: AgentUpdate<Output>) {
        let metadata: Logger.Metadata = ["agentID": .string(agentID.rawValue)]
        switch update {
        case .run(.event(.modelOutputGenerated(_, _))):
            logger.debug("Agent forwarding typed model output", metadata: metadata)
        case .run(.event(.toolRequested(let toolCall, _))):
            logger.info(
                "Agent forwarding tool request",
                metadata: metadata.merging(
                    ["tool": .string(toolCall.name)], uniquingKeysWith: { _, new in new })
            )
        case .run(.event(.toolCompleted(let result, _))):
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
        case .rateLimit:
            return .rateLimit
        case .contextLengthExceeded:
            return .contextLengthExceeded
        case .invalidRequest(let reason):
            return .modelMisbehavior("invalid request: \(reason)")
        case .requestFailed(let reason):
            return .modelMisbehavior(HailErrorFormatter.sanitizedModelOutput(reason))
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
        return .modelMisbehavior(String(describing: error))
    }

    private static func durationMilliseconds(since start: ClockType.Instant, now: ClockType.Instant) -> Int {
        let components = start.duration(to: now).components
        let milliseconds =
            components.seconds.multipliedReportingOverflow(by: 1_000).partialValue
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }
}
