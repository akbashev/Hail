import ACPModel
import HailCore
import Logging
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let codexSessionLogger = Logger(label: "CodexAppServerSession")

enum CodexNarration: Sendable {
    case text(String)
    case thinking(String)
    case status(String)
}

/// Owns Codex thread identity and warm/cold turn routing. Wire transport lives
/// in `CodexAppServerClient`; effect decisions live in `CodexAuthorityAdapter`.
actor CodexAppServerSession {
    private let model: String
    private let workingDirectory: String
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let executionPolicy: AgentExecutionPolicy
    private let reasoningEffort: ReasoningEffort?
    private let client: CodexAppServerClient
    private let creationAuthority: any Authority

    private var sessionID: SessionID?
    private var liveSessionID: String?
    private var sessionIdentity: SessionIdentity?
    private var threadIsAttached = false
    private var lastMemorySnapshot: String?

    /// Stall ceiling. A turn produces app-server traffic as it works, so a
    /// turn silent for this long is live-but-wedged (upstream stall,
    /// swallowed error) and is failed instead of hanging forever. Process
    /// death needs no probe here — it already surfaces as transport EOF
    /// (`disconnect`) — so unlike `ACPSession.watchForStall` there is only
    /// the ceiling, no probe round. Defaults to 30 minutes like the ACP
    /// ceiling; `HAIL_CODEX_MAX_STALL_TIMEOUT` (seconds) overrides.
    private let maxStallDuration: TimeInterval
    private let heartbeatInterval: TimeInterval = 15

    /// Monotonic timestamp of the last app-server envelope in the current
    /// turn, read by the stall watchdog. Turns are serialized per session, so
    /// one actor property suffices — everything touching it is already
    /// actor-isolated, no lock needed.
    private var turnLastActivity: ContinuousClock.Instant = .now

    var currentSessionID: SessionID? { sessionID }

    init(
        model: String,
        workingDirectory: String,
        agentID: String?,
        contextLabel: String?,
        mcpServerConfiguration: MCPServerConfiguration?,
        executionPolicy: AgentExecutionPolicy,
        reasoningEffort: ReasoningEffort? = nil,
        executablePath: String,
        resumeSession: ModelSessionResume?,
        authority: any Authority,
        maxStallDuration: TimeInterval? = nil
    ) throws(ModelRouterError) {
        self.model = model
        self.workingDirectory = workingDirectory
        self.mcpServerConfiguration = mcpServerConfiguration
        self.executionPolicy = executionPolicy
        self.reasoningEffort = reasoningEffort
        self.creationAuthority = authority
        self.maxStallDuration = try ProcessEnvironment.timeInterval(
            override: maxStallDuration,
            from: "HAIL_CODEX_MAX_STALL_TIMEOUT",
            default: 1800
        )
        self.sessionID = resumeSession?.id
        self.sessionIdentity = resumeSession?.identity
        self.client = CodexAppServerClient(
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            environment: mcpServerConfiguration?.environment(
                agentID: agentID,
                context: contextLabel
            ) ?? [:],
            authority: authority
        )
    }

    func runTurn(
        fullPrompt: String,
        deltaPrompt: String?,
        identity: SessionIdentity?,
        memorySnapshot: String?,
        outputSchema: Data?,
        turnAuthority: (any Authority)?,
        onNarration: @escaping @Sendable (CodexNarration) -> Void
    ) async throws -> String {
        // Stall watchdog: any app-server traffic (responses, notifications,
        // approval requests) touches the clock; a turn silent for
        // `maxStallDuration` is wedged, so the connection is reset — which
        // fails the pending request or ends the event loop — instead of the
        // turn hanging forever.
        turnLastActivity = .now
        let watchdog = Task { await self.watchForStall() }
        defer { watchdog.cancel() }
        do {
            try await client.connect()
            let prompt = try await prepareThread(
                fullPrompt: fullPrompt,
                deltaPrompt: deltaPrompt,
                identity: identity,
                memorySnapshot: memorySnapshot
            )
            guard let sessionID else { throw CodexSessionError.missingThreadID }
            return try await executeTurn(
                prompt: prompt,
                threadID: sessionID.rawValue,
                outputSchema: outputSchema,
                authority: turnAuthority ?? creationAuthority,
                onNarration: onNarration
            )
        } catch CodexSessionError.cancelled {
            throw CodexSessionError.cancelled
        } catch is CancellationError {
            // An abandoned turn says nothing about the connection: the
            // app-server stays up and the warm thread attachment survives,
            // so the next turn reuses both instead of cold-bootstrapping.
            throw CodexSessionError.cancelled
        } catch {
            await resetConnection(preservingThread: true)
            throw error
        }
    }

    private func prepareThread(
        fullPrompt: String,
        deltaPrompt: String?,
        identity: SessionIdentity?,
        memorySnapshot: String?
    ) async throws -> String {
        let sessionTurn = identity != nil && deltaPrompt != nil
        let sameIdentity = sessionTurn && sessionIdentity == identity

        if sameIdentity, threadIsAttached, sessionID != nil {
            return warmPrompt(deltaPrompt!, memorySnapshot: memorySnapshot)
        }
        if sameIdentity, let durableID = sessionID {
            do {
                try await attachThread(durableID)
                return warmPrompt(deltaPrompt!, memorySnapshot: memorySnapshot)
            } catch {
                codexSessionLogger.warning(
                    "Could not resume Codex thread; cold-bootstrapping",
                    metadata: [
                        "threadID": .string(durableID.rawValue),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        }

        sessionIdentity = identity
        sessionID = nil
        threadIsAttached = false
        lastMemorySnapshot = memorySnapshot
        try await startThread()
        return fullPrompt
    }

    private func warmPrompt(_ delta: String, memorySnapshot: String?) -> String {
        var parts: [String] = []
        if let memorySnapshot, memorySnapshot != lastMemorySnapshot {
            parts.append(memorySnapshot)
            lastMemorySnapshot = memorySnapshot
        }
        parts.append(delta)
        return parts.joined(separator: "\n\n")
    }

    private func startThread() async throws {
        try acceptThread(
            await client.request(
                "thread/start",
                params: threadParameters(threadID: nil)
            )
        )
    }

    private func attachThread(_ id: SessionID) async throws {
        try acceptThread(
            await client.request(
                "thread/resume",
                params: threadParameters(threadID: id.rawValue)
            )
        )
    }

    private func acceptThread(_ response: CodexRPCEnvelope) throws {
        guard let thread = try response.result?.decode(CodexThreadResponse.self).thread else {
            throw CodexSessionError.missingThreadID
        }
        // Hail's durable SessionID is the resumable thread id. Codex's
        // `sessionId` is a different value: it identifies the root of the live
        // session tree and is not the id sent to `thread/resume` or `turn/start`.
        // Keep both identities distinct; they happen to be equal for root
        // threads, which is why this mistake is easy to miss.
        sessionID = SessionID(thread.id)
        liveSessionID = thread.sessionId
        threadIsAttached = true
    }

    private func executeTurn(
        prompt: String,
        threadID: String,
        outputSchema: Data?,
        authority: any Authority,
        onNarration: @Sendable (CodexNarration) -> Void
    ) async throws -> String {
        let adapter = CodexAuthorityAdapter(
            workingDirectory: workingDirectory,
            authority: authority
        )
        let turnResponse = try await client.request(
            "turn/start",
            params: CodexTurnStartParams(
                threadId: threadID,
                input: [.init(type: "text", text: prompt)],
                cwd: workingDirectory,
                approvalPolicy: "on-request",
                sandboxPolicy: await adapter.sandboxPolicy(),
                runtimeWorkspaceRoots: await adapter.workspaceRoots(),
                effort: reasoningEffort?.rawValue,
                outputSchema: try outputSchema.map(AnyCodable.decode(from:))
            )
        )
        let turnID = try turnResponse.result?.decode(CodexTurnResponse.self).turn.id
        guard let turnID else { throw CodexSessionError.turnFailed("Codex returned no turn id.") }
        let events = try await client.events()

        var finalText = ""
        var sawTextDelta = false
        var pendingFileChanges: [String: [String]] = [:]
        for await message in events {
            // Every envelope — notifications and server-initiated approval
            // requests alike — is proof of life for the stall watchdog.
            turnLastActivity = .now
            if let method = message.method, message.id != nil {
                try await client.send(
                    adapter.response(
                        to: message,
                        method: method,
                        expectedThreadID: threadID,
                        expectedTurnID: turnID,
                        pendingFileChanges: pendingFileChanges
                    )
                )
                continue
            }
            guard let method = message.method else { continue }
            switch method {
            case "item/agentMessage/delta":
                if let delta = try message.params?.decode(CodexTextDelta.self).delta, !delta.isEmpty {
                    sawTextDelta = true
                    finalText += delta
                    onNarration(.text(delta))
                }
            case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
                if let delta = try message.params?.decode(CodexTextDelta.self).delta, !delta.isEmpty {
                    onNarration(.thinking(delta))
                }
            case "item/started", "item/completed":
                guard let item = try message.params?.decode(CodexItemNotification.self).item else {
                    continue
                }
                track(item: item, method: method, with: adapter, in: &pendingFileChanges)
                if method == "item/completed", item.type == "agentMessage",
                    let text = item.text, !text.isEmpty
                {
                    finalText = text
                    if !sawTextDelta { onNarration(.text(text)) }
                } else {
                    narrate(item: item, started: method == "item/started", to: onNarration)
                }
            case "turn/completed":
                if let turn = try message.params?.decode(CodexTurnCompleted.self).turn,
                    turn.status != "completed"
                {
                    throw CodexSessionError.turnFailed(
                        turn.error?.message ?? "Codex turn ended with status \(turn.status).")
                }
                return finalText
            case "error":
                throw CodexSessionError.turnFailed(
                    try message.params?.decode(CodexErrorNotification.self).message
                        ?? "Codex App Server error."
                )
            default:
                break
            }
        }
        // The event stream ended mid-turn. If the consumer cancelled, this is
        // an abandoned turn, not a lost connection: the app-server is still
        // healthy, so classify it as cancellation — `runTurn` must not tear
        // the connection down for it.
        if Task.isCancelled {
            // But the local iterator stopping does not stop the *server-side*
            // turn: without an interrupt the thread stays busy, and the next
            // turn on it would receive stale events or overlap model effects.
            // Fire-and-forget — the teardown must not block on a wedged
            // server; reset-on-doubt covers a missed interrupt.
            Task {
                do {
                    _ = try await client.request(
                        "turn/interrupt",
                        params: CodexTurnInterruptParams(threadId: threadID, turnId: turnID)
                    )
                } catch {
                    codexSessionLogger.debug(
                        "Best-effort Codex turn interrupt failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }
            throw CodexSessionError.cancelled
        }
        throw CodexSessionError.disconnected
    }

    private func track(
        item: CodexItemNotification.Item,
        method: String,
        with adapter: CodexAuthorityAdapter,
        in pending: inout [String: [String]]
    ) {
        guard let itemID = item.id else { return }
        if method == "item/started", item.type == "fileChange" {
            pending[itemID] = item.changes?.map { adapter.absolutePath($0.path) } ?? []
        } else if method == "item/completed" {
            pending[itemID] = nil
        }
    }

    private func narrate(
        item: CodexItemNotification.Item,
        started: Bool,
        to onNarration: @Sendable (CodexNarration) -> Void
    ) {
        switch item.type {
        case "commandExecution": onNarration(.status(started ? "Running command." : "Ran command."))
        case "mcpToolCall":
            let action = started ? "Calling" : "Called"
            onNarration(.status("\(action) \(item.server ?? "MCP").\(item.tool ?? "tool")."))
        case "fileChange": onNarration(.status(started ? "Updating files." : "Updated files."))
        default: break
        }
    }

    private func threadParameters(threadID: String?) -> CodexThreadParams {
        CodexThreadParams(
            model: model,
            cwd: workingDirectory,
            approvalPolicy: executionPolicy.approvalPolicy.rawValue,
            sandbox: executionPolicy.sandbox.rawValue,
            serviceName: "hail",
            config: appServerConfiguration,
            threadId: threadID
        )
    }

    private var appServerConfiguration: CodexThreadConfig? {
        guard let configuration = mcpServerConfiguration else { return nil }
        let environmentKeys = [
            configuration.agentIDEnvironmentKey,
            configuration.contextEnvironmentKey,
        ].compactMap { $0 }
        return CodexThreadConfig(
            mcpServers: [
                configuration.name: .init(
                    command: configuration.command,
                    args: configuration.arguments,
                    envVars: environmentKeys,
                    enabled: true,
                    required: true,
                    defaultToolsApprovalMode: "approve"
                )
            ]
        )
    }

    /// Monitors app-server traffic while a turn is in flight. Once the turn
    /// has been silent for `maxStallDuration` it is failed regardless of
    /// process health — liveness is not progress — by resetting the
    /// connection, which resumes any parked request and finishes the event
    /// stream with `CodexSessionError.disconnected`. Mirrors
    /// `ACPSession.watchForStall`'s ceiling, minus the probe: process death
    /// already surfaces as transport EOF here, so the only case the ceiling
    /// must cover is a live-but-silent server.
    private func watchForStall() async {
        // Never check less often than the ceiling itself, so short ceilings
        // (tests, aggressive configs) are still honored promptly.
        let checkInterval = min(heartbeatInterval, maxStallDuration)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(checkInterval))
            guard !Task.isCancelled else { return }
            let idle = ContinuousClock.now - turnLastActivity
            guard idle >= .seconds(maxStallDuration) else { continue }
            codexSessionLogger.error(
                "Codex turn made no progress within the stall ceiling; resetting so the turn fails",
                metadata: [
                    "idleSeconds": .string("\(idle.components.seconds)"),
                    "maxStallSeconds": .string("\(Int(maxStallDuration))"),
                ]
            )
            await resetConnection(preservingThread: true)
            return
        }
    }

    private func resetConnection(preservingThread: Bool) async {
        await client.close()
        threadIsAttached = false
        if !preservingThread {
            sessionID = nil
            liveSessionID = nil
            sessionIdentity = nil
            lastMemorySnapshot = nil
        }
    }

    func terminate() async {
        await resetConnection(preservingThread: false)
    }
}
