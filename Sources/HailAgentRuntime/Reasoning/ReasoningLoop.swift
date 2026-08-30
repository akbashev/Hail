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

/// Pure reducer that turns a stream of ``ModelEvent`` values into the typed
/// run events of an ``AgentUpdate``. Narration (status/thinking/text/tool) is
/// recorded on the activity stream by the loop; only control and the typed
/// outcome are emitted here.
private enum TurnReducer {
    static func reduce<Output: Codable & Sendable>(
        state: TurnState,
        event: ModelEvent<Output>
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
            return (.idle, [.run(.event(.toolRequested(toolCall: call, at: Date())))])

        case (_, .generated(let value)):
            if Output.self != String.self {
                return (.idle, [.run(.event(.modelOutputGenerated(content: value, at: Date())))])
            }
            return (.idle, [])

        case (_, .partialUpdated):
            return (.idle, [])

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
    var messages: [LLMMessage]
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
struct ReasoningLoop: Sendable {
    /// The hosting agent's identity. Used to attribute journaled responses and
    /// to decide whether a `.response` message was authored by this agent.
    let agentID: AgentID

    /// The effect authority this turn runs under (the turn's lane, or the
    /// agent's default). Handed to session-owning endpoints alongside the
    /// ``TurnDelta`` so the harness's own effects (fs/terminal delegation,
    /// process spawns) are checked against the same lane as the tool registry.
    let authority: any Authority

    /// Builds the prompt context (system prompt, memory, conversation thread,
    /// context manifest) for one turn.
    let context: @Sendable () async -> TurnContext

    /// Resolves the model endpoint for this turn.
    let endpoint: @Sendable () async throws -> ModelEndpoint

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
    private static let maxToolRounds = 25

    private let logger: Logger

    init(
        agentID: AgentID,
        logger: Logger = Logger(label: "hail.reasoning-loop"),
        authority: any Authority,
        context: @escaping @Sendable () async -> TurnContext,
        endpoint: @escaping @Sendable () async throws -> ModelEndpoint,
        tools: @escaping @Sendable () async throws -> ToolRegistry,
        emit: @escaping @Sendable (AgentEvent) async throws -> Void,
        recordActivity: @escaping @Sendable (AgentActivity) async -> Void
    ) {
        self.agentID = agentID
        self.logger = logger
        self.authority = authority
        self.context = context
        self.endpoint = endpoint
        self.tools = tools
        self.emit = emit
        self.recordActivity = recordActivity
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
                try? await emit(.turnFailed(error: runtimeError, at: at))
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
        let turnStartedAt = Date()

        // Per-turn wall-clock timing, logged on every exit path (success,
        // failure, cancellation) so slow turns are visible in the logs.
        defer {
            logger.info(
                "Turn ended",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "durationMs": .string("\(Int(Date().timeIntervalSince(turnStartedAt) * 1000))"),
                ]
            )
        }

        let registry = try await tools()
        let turnContext = await context()
        var messages = turnContext.messages
        // The turn delta is everything appended after the assembled context:
        // per-turn instructions followed by the new input message. On a warm
        // session-owning endpoint this is all the harness receives — the
        // session already holds the history.
        var deltaMessages: [LLMMessage] = []
        let turnClockInstruction = LLMMessage(
            role: .system,
            content:
                "Turn started at \(turnStartedAt.ISO8601Format()). Use this timestamp as the current time at the beginning of the turn."
        )
        messages.append(turnClockInstruction)
        deltaMessages.append(turnClockInstruction)

        for instruction in input.systemInstructions() {
            let instructionMessage = LLMMessage(role: .system, content: instruction)
            messages.append(instructionMessage)
            deltaMessages.append(instructionMessage)
        }
        switch message {
        case .text(let sender, let content, _):
            let inputMessage = LLMMessage(role: .user, content: content, name: sender)
            messages.append(inputMessage)
            deltaMessages.append(inputMessage)
        case .response(let sender, let payload, _):
            if let content = try? JSONDecoder().decode(String.self, from: payload), !content.isEmpty {
                let inputMessage = LLMMessage(
                    role: sender == agentID.rawValue ? .assistant : .user,
                    content: content
                )
                messages.append(inputMessage)
                deltaMessages.append(inputMessage)
            }
        case .toolCall(let calls, _):
            let inputMessage = LLMMessage(
                role: .assistant,
                content: "",
                toolCalls: calls.map { LLMToolCall($0) }
            )
            messages.append(inputMessage)
            deltaMessages.append(inputMessage)
        case .toolResult(let id, let content, _):
            let inputMessage = LLMMessage(role: .tool, content: content, toolCallID: id)
            messages.append(inputMessage)
            deltaMessages.append(inputMessage)
        case .failure:
            // Turn failures are transcript-only; the model never sees them.
            break
        case .decisionRequest, .decisionResolved:
            // Display-only messages; the model learns about resolutions
            // through the ask_user tool result or resume messages.
            break
        }
        let delta = TurnDelta(
            messages: deltaMessages,
            workingMemory: turnContext.workingMemory,
            sessionIdentity: turnContext.sessionIdentity
        )

        let endpoint = try await self.endpoint()

        guard
            let outcome = try await runTurn(
                messages: &messages,
                delta: delta,
                registry: registry,
                endpoint: endpoint,
                through: connection
            )
        else {
            await broadcast(.run(.event(.runCompleted(at: Date()))), to: connection)
            return
        }

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

    /// Pure model/tool loop. Returns the first generated value of type `Output`
    /// that the endpoint produces, or `nil` if the turn ended without one.
    private func runTurn<Output: AgentOutput>(
        messages: inout [LLMMessage],
        delta: TurnDelta,
        registry: ToolRegistry,
        endpoint: ModelEndpoint,
        through connection: AgentConnection<Output>
    ) async throws -> Output? {
        var toolRounds = 0
        while true {
            try Task.checkCancellation()
            let schemas = await registry.schemas()
            let tools = schemas.isEmpty ? nil : schemas

            // Session-owning endpoints (Kimi/Claude/Codex harnesses) receive the per-turn
            // delta and the turn's authority, and decide warm-vs-bootstrap
            // themselves; stateless endpoints always get the full assembled
            // context (their authority is creation-time only).
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
            var turnToolCalls: [ToolCall] = []
            var turnText = ""
            var turnThinking = ""
            var outcome: Output?

            for await event in stream {
                let (nextState, updates) = TurnReducer.reduce(state: turnState, event: event)
                turnState = nextState
                for update in updates {
                    await broadcast(update, to: connection)
                }

                switch event {
                case .text(let fragment):
                    turnText += fragment
                    await recordActivity(.turn(.progress(.text(turnText)), at: Date()))
                case .thinking(let fragment):
                    turnThinking += fragment
                    await recordActivity(.turn(.progress(.reasoning(turnThinking)), at: Date()))
                case .status(let message):
                    await recordActivity(.turn(.progress(.status(message)), at: Date()))
                case .toolCall(let call):
                    turnToolCalls.append(call)
                    await recordActivity(.turn(.progress(.tool(name: call.name)), at: Date()))
                case .generated(let value):
                    outcome = value
                case .partialUpdated:
                    break
                case .failed(let modelError):
                    throw Self.map(modelError: modelError)
                }
            }

            if !turnToolCalls.isEmpty {
                // Reject the excess round *before* its tools run: the cap
                // must prevent round 26's side effects, not merely fail after
                // them — and before `toolInvoked` journaling, so the journal
                // never holds tool events without matching results.
                toolRounds += 1
                guard toolRounds <= Self.maxToolRounds else {
                    throw AgentRuntimeError.modelMisbehavior(
                        "Model exceeded the maximum of \(Self.maxToolRounds) tool rounds in a single turn."
                    )
                }
                messages.append(
                    LLMMessage(
                        role: .assistant,
                        content: turnText,
                        toolCalls: turnToolCalls.map { LLMToolCall($0) }
                    )
                )

                for toolCall in turnToolCalls {
                    try await emit(.toolInvoked(toolCall, at: Date()))
                }

                let toolRoundStartedAt = Date()
                let results = try await registry.execute(turnToolCalls)
                try Task.checkCancellation()
                logger.info(
                    "Tool round finished",
                    metadata: [
                        "agentID": .string(agentID.rawValue),
                        "tools": .string(turnToolCalls.map(\.name).joined(separator: ",")),
                        "durationMs": .string("\(Int(Date().timeIntervalSince(toolRoundStartedAt) * 1000))"),
                    ]
                )
                for result in results {
                    messages.append(
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

                continue
            }

            if let outcome {
                return outcome
            }

            // Fallback for endpoints that stream text without a terminal
            // generated event.
            if !turnText.isEmpty, let fallback = try? Output(GeneratedContent(json: turnText)) {
                return fallback
            }

            return nil
        }
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
}
