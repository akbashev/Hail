import ACP
import ACPModel
import HailCore
import Logging
import ScopedEffect
import Synchronization

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let logger = Logger(label: "ACPSession")

/// Manages a long-lived Agent Client Protocol (ACP) session for a local CLI
/// agent such as `kimi-code` or Claude Code.
///
/// The transport is provider-neutral: the agent command is injected as
/// `agentPath` + `agentArguments`, so any CLI that speaks ACP over stdio can be
/// driven through this one actor. Instead of launching a fresh agent process
/// (and fresh MCP subprocess) for every LLM request, it keeps one session open
/// and reuses it.
///
/// The stall-watchdog tuning environment variables keep their historical
/// `HAIL_KIMI_*` names so existing configuration is unaffected; they apply
/// to every ACP agent, not just kimi.
///
/// All prompt-handling state is scoped to a single prompt call. There is no
/// shared notification collector and no prompt metadata retained on the actor
/// after a call returns.
actor ACPSession {
    private let model: String
    private let workingDirectory: String
    private let agentID: String?
    private let contextLabel: String?
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let agentPath: String
    private let agentArguments: [String]
    /// The authority the harness process spawn is scoped against, fixed at
    /// creation. The spawn is endpoint infrastructure — fixed binary and
    /// arguments from configuration, no model influence — so it deliberately
    /// ignores per-turn lanes: a deny-everything lane (e.g.
    /// ``CompositeAuthority/untrustedInput``) must never make the turn itself
    /// impossible. Model-decided effects (the delegate's file/terminal checks)
    /// follow the turn's lane instead — see `activeAuthority`.
    private let authority: any Authority

    /// The authority in force for the current turn's *model-facing* effects.
    /// Set at prompt start from the turn's lane (or left at the creation
    /// default); turns are serialized per agent, so applying it here needs no
    /// restore — the next prompt simply sets its own. `ensureClient` hands it
    /// to the client delegate; the harness spawn uses `authority` instead.
    private var activeAuthority: any Authority

    private var client: ACP.Client?
    private var delegate: KimiACPClientDelegate?

    /// Registration of one in-flight prompt's event sink. The single
    /// notification consumer (see ``ensureClient()``) routes session updates
    /// here by session id.
    private struct PromptStream {
        let sessionId: SessionId
        let continuation: AsyncThrowingStream<ACPPromptEvent, Error>.Continuation
        /// Monotonic timestamp of the last routed notification, read by the
        /// stall watchdog. Actor-isolated like everything else here — no lock.
        var lastActivity: ContinuousClock.Instant
    }

    /// swift-acp's `client.notifications` is a single-consumer `AsyncStream`:
    /// once an iterator is cancelled, later iterators starve forever (verified
    /// against the real CLI — turn 0 of a session renders, every following
    /// turn silently drops all updates). So there is exactly ONE consumer per
    /// client, started with it, and per-prompt streams are demultiplexed from
    /// it. Never iterate `client.notifications` anywhere else.
    private var notificationTask: Task<Void, Never>?

    /// When the last notification was routed, monotonic. The prompt finish
    /// path waits for this to go quiet — see
    /// ``finishPromptStreamWhenRoutingSettles(_:)``.
    private var lastRoutedAt: ContinuousClock.Instant = .now
    private var promptStreams: [UUID: PromptStream] = [:]
    private var sessionId: SessionId?

    /// Set when a prompt's consumer cancels — meaning the harness may still be
    /// running that prompt, so the next turn must cold-start, not warm-delta.
    /// This is a `Mutex`, not actor state, on purpose: it is written from the
    /// stream's `onTermination`, which is *not* actor-isolated, and an actor
    /// hop from there could be reordered after the next prompt's own hop —
    /// exactly the interleaving the flag exists to prevent.
    private let cancelledPrompt = Mutex(false)

    /// The agent identity fingerprint the live session was bootstrapped with
    /// (see ``AgentSessionIdentity``). A mismatch on the next turn invalidates
    /// the session and forces a full bootstrap.
    private var sessionIdentity: SessionIdentity?

    /// The working-memory snapshot last sent to the live session. Re-sent only
    /// when it changes.
    private var lastMemorySnapshot: String?

    /// The journaled session to resume on the first turn, if any. Consumed on
    /// the first session setup attempt.
    private var resumeSession: ModelSessionResume?

    /// The live harness session id, exposed for journaling.
    var currentSessionID: SessionID? {
        sessionId.map { SessionID($0.value) }
    }

    /// Result of a completed prompt, including the generated text and the
    /// completion metadata returned by the ACP `session/prompt` response.
    struct PromptResult: Sendable {
        let text: String
        let stopReason: StopReason
        let usage: Usage?
    }

    /// A native ACP notification emitted while a prompt is being processed.
    ///
    /// This is the raw stream from the `kimi-code` agent; callers map it to
    /// their own domain events (e.g. ``ModelEvent``).
    enum ACPPromptEvent: Sendable {
        case text(String)
        case thought(String)
        case toolCall(ToolCallUpdate)
        case toolCallUpdate(ToolCallUpdateDetails)
        case plan(Plan)
        case usage(UsageUpdate)
    }

    // Session setup timeouts guard against a hung `kimi-code` process. The
    // actual prompt/response loop has no timeout because model responses can
    // take minutes or longer.
    private let initializeTimeout: TimeInterval = ProcessEnvironment.timeInterval(
        from: "HAIL_KIMI_INITIALIZE_TIMEOUT", default: 30)
    private let newSessionTimeout: TimeInterval = ProcessEnvironment.timeInterval(
        from: "HAIL_KIMI_SESSION_TIMEOUT", default: 120)
    private let heartbeatInterval: TimeInterval = 15

    // Stall watchdog. A prompt can legitimately produce no ACP traffic for a
    // long time (slow model, a long delegated terminal command), so a silent
    // turn is never killed on a timer alone: after `stallTimeout` without any
    // traffic the session is probed with a lightweight `session/list` request.
    // A process that cannot answer even that (wedged event loop, dead without
    // termination propagating) has its turn failed and session reset at once.
    //
    // A process that *does* answer the probe is alive, but "alive" is not
    // "making progress": an upstream stall (dropped provider connection,
    // swallowed internal error, server-side queueing) leaves the event loop
    // healthy while the turn never advances. So a probe success does not reset
    // the idle clock — it only buys time. Once the turn has been silent for
    // `maxStallDuration` with no ACP traffic at all, it is failed regardless of
    // probe health, so a live-but-wedged turn can never hang forever.
    private let stallTimeout: TimeInterval
    private let probeTimeout: TimeInterval
    private let maxStallDuration: TimeInterval

    init(
        model: String,
        workingDirectory: String,
        agentID: String? = nil,
        contextLabel: String? = nil,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        agentPath: String,
        agentArguments: [String],
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        stallTimeout: TimeInterval? = nil,
        probeTimeout: TimeInterval? = nil,
        maxStallDuration: TimeInterval? = nil
    ) {
        self.model = model
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.contextLabel = contextLabel
        self.mcpServerConfiguration = mcpServerConfiguration
        self.agentPath = agentPath
        self.agentArguments = agentArguments
        self.resumeSession = resumeSession
        self.authority = authority ?? FullAuthority()
        self.activeAuthority = self.authority
        self.stallTimeout =
            stallTimeout
            ?? ProcessEnvironment.timeInterval(from: "HAIL_KIMI_STALL_TIMEOUT", default: 600)
        self.probeTimeout =
            probeTimeout
            ?? ProcessEnvironment.timeInterval(from: "HAIL_KIMI_PROBE_TIMEOUT", default: 60)
        self.maxStallDuration =
            maxStallDuration
            ?? ProcessEnvironment.timeInterval(from: "HAIL_KIMI_MAX_STALL_TIMEOUT", default: 1800)
    }

    /// Sends a prompt to the kimi-code ACP session and returns the final text
    /// plus the ACP completion metadata.
    func sendPrompt(_ text: String) async throws -> PromptResult {
        logger.info(
            "Sending prompt to kimi-code",
            metadata: [
                "agentID": .string(agentID ?? "-"),
                "contextLabel": .string(contextLabel ?? "-"),
                "length": .string("\(text.count)"),
            ]
        )

        do {
            let (stream, responseTask) = try await executePrompt(text)

            var collected = ""
            for try await event in stream {
                if case .text(let fragment) = event {
                    collected += fragment
                }
            }

            let response = try await responseTask.value

            logger.info(
                "Received response from kimi-code",
                metadata: [
                    "length": .string("\(collected.count)"),
                    "stopReason": .string("\(response.stopReason)"),
                ]
            )

            return PromptResult(
                text: collected,
                stopReason: response.stopReason,
                usage: response.usage
            )
        } catch {
            logger.error(
                "Prompt failed, resetting ACP session",
                metadata: ["error": .string(String(describing: error))]
            )
            await reset()
            throw error
        }
    }

    /// Streams a prompt to the kimi-code ACP session, yielding text fragments
    /// as they arrive from the agent message chunks.
    ///
    /// Completion metadata is logged but not returned; use `sendPrompt(_:)` if
    /// you need the `stopReason` or `usage`.
    func streamPrompt(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (stream, responseTask) = try await executePrompt(text)

                    for try await event in stream {
                        if case .text(let fragment) = event {
                            continuation.yield(fragment)
                        }
                    }

                    let response = try await responseTask.value
                    logger.info(
                        "kimi-code prompt completed",
                        metadata: ["stopReason": .string("\(response.stopReason)")]
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt handling

    /// Routes one turn to the ACP session.
    ///
    /// Warm path — the session is alive and its identity fingerprint matches:
    /// send only the turn's delta (plus the memory snapshot when it changed).
    /// Cold path — no session, or the agent's identity changed: drop whatever
    /// is left and bootstrap a fresh session with the full transcript.
    ///
    /// Unlike the old full-resend model, warm deltas are not self-healing, so
    /// any failure resets the session ("reset on doubt"): the next turn then
    /// bootstraps from the journal, which stays the durable source of truth.
    ///
    /// `authority` is the turn's effect lane: it becomes the session's active
    /// authority for this prompt, governing the *model-facing* effects — the
    /// delegate's fs/terminal checks. The harness spawn is not model-facing
    /// and stays scoped against the session's creation authority. `nil`
    /// keeps the current authority. Turns are serialized per agent, so no
    /// restore is needed — the next prompt sets its own.
    func executeTurnPrompt(
        bootstrap: String,
        delta: String,
        memorySnapshot: String?,
        identity: SessionIdentity,
        authority: (any Authority)? = nil
    ) async throws -> (
        stream: AsyncThrowingStream<ACPPromptEvent, Error>,
        response: Task<SessionPromptResponse, Error>
    ) {
        if let authority {
            activeAuthority = authority
            delegate?.setAuthority(authority)
        }
        let text: String
        // A cancelled prompt leaves the session's turn state unknown (see
        // `cancelledPrompt`), so it forces the cold path like an identity
        // change. Read-and-clear: the flag covers exactly one cold start.
        let promptWasCancelled = cancelledPrompt.withLock { flagged in
            defer { flagged = false }
            return flagged
        }
        if !promptWasCancelled, sessionId != nil, sessionIdentity == identity {
            var parts: [String] = []
            if let memorySnapshot, memorySnapshot != lastMemorySnapshot {
                parts.append(memorySnapshot)
                lastMemorySnapshot = memorySnapshot
            }
            parts.append(delta)
            text = parts.joined(separator: "\n\n")
            logger.info(
                "Sending warm delta to ACP session",
                metadata: [
                    "agentID": .string(agentID ?? "-"),
                    "length": .string("\(text.count)"),
                ]
            )
        } else {
            await reset()
            sessionIdentity = identity
            lastMemorySnapshot = memorySnapshot
            if let resumed = try? await resumeJournaledSession(identity: identity), resumed {
                // The CLI session already holds the history — only the delta
                // is new. Memory is re-sent once because the journaled
                // snapshot may postdate what the session last saw.
                lastMemorySnapshot = nil
                var parts: [String] = []
                if let memorySnapshot {
                    parts.append(memorySnapshot)
                    lastMemorySnapshot = memorySnapshot
                }
                parts.append(delta)
                text = parts.joined(separator: "\n\n")
                logger.info(
                    "Resumed ACP session; sending delta",
                    metadata: [
                        "agentID": .string(agentID ?? "-"),
                        "length": .string("\(text.count)"),
                    ]
                )
            } else {
                text = bootstrap
                logger.info(
                    "Bootstrapping fresh ACP session with full transcript",
                    metadata: [
                        "agentID": .string(agentID ?? "-"),
                        "length": .string("\(text.count)"),
                    ]
                )
            }
        }

        do {
            let (stream, response) = try await executePrompt(text)
            // A failed turn leaves the session's context uncertain (the agent
            // may have seen part of the prompt), so reset on doubt.
            let monitored = Task {
                do {
                    return try await response.value
                } catch is CancellationError {
                    // A consumer cancellation already forces the next turn
                    // down the cold path via `cancelledPrompt`; an async
                    // reset here could land *after* that turn's own
                    // bootstrap and kill it.
                    throw CancellationError()
                } catch {
                    await self.reset()
                    throw error
                }
            }
            return (stream, monitored)
        } catch {
            await reset()
            throw error
        }
    }

    /// Starts a prompt and returns:
    /// - a stream of native ACP notifications for this prompt only, scoped to
    ///   the current ACP `sessionId`;
    /// - a task that resolves to the ACP `session/prompt` response once the
    ///   agent finishes the turn.
    ///
    /// All state created by this call (the notification collector, the stream
    /// continuation, and the response task) is scoped to the returned values.
    func executePrompt(
        _ text: String
    ) async throws -> (
        stream: AsyncThrowingStream<ACPPromptEvent, Error>,
        response: Task<SessionPromptResponse, Error>
    ) {
        let client = try await ensureClient()
        let sessionId = try await ensureSession(client: client)

        let (stream, streamContinuation) = AsyncThrowingStream<ACPPromptEvent, Error>.makeStream()
        let registrationID = UUID()
        // `lastActivity` is updated on every routed ACP notification for this
        // prompt's session; the watchdog reads it to distinguish a
        // busy-but-silent turn (a long terminal command produces no traffic)
        // from a wedged process.
        promptStreams[registrationID] = PromptStream(
            sessionId: sessionId,
            continuation: streamContinuation,
            lastActivity: .now
        )

        let responseTask = Task {
            do {
                let response = try await client.sendPrompt(
                    sessionId: sessionId,
                    content: [.text(TextContent(text: text))]
                )
                await self.finishPromptStreamWhenRoutingSettles(streamContinuation)
                return response
            } catch is CancellationError {
                // A cancelled consumer wants the stream closed now; the final
                // chunk is moot, so skip the settle wait.
                streamContinuation.finish()
                throw CancellationError()
            } catch {
                await self.finishPromptStreamWhenRoutingSettles(streamContinuation)
                throw error
            }
        }

        // Stall watchdog: a live but silent process is left alone as long as it
        // answers the probe; a wedged one has its session torn down, which fails
        // the pending prompt (`Client.terminate` resumes it) instead of hanging
        // the turn — and the assignment — forever.
        let watchdogTask = Task {
            await self.watchForStall(client: client, registrationID: registrationID)
        }
        // The stream ends when the prompt resolves or fails (which is also
        // when the watchdog becomes obsolete) — or when the consumer cancels.
        // A cancelled consumer means Hail considers the turn over, so the
        // harness must hear about it: without `session/cancel` it would keep
        // executing fs/terminal effects, and the next turn's warm delta would
        // interleave into the still-running prompt in the same session. The
        // notification is fire-and-forget: termination must not block on a
        // harness that may be wedged.
        streamContinuation.onTermination = { termination in
            watchdogTask.cancel()
            if case .cancelled = termination {
                responseTask.cancel()
                Task { try? await client.cancelSession(sessionId: sessionId) }
                // But `session/cancel` is not reliably observed mid-turn, and
                // the prompt's continuation may never resume — so the next
                // turn must not warm-delta into the possibly still-running
                // prompt. The flag forces its cold path (which resets before
                // re-bootstrapping); an async reset here could instead land
                // *after* the next prompt's own bootstrap and kill it.
                self.cancelledPrompt.withLock { $0 = true }
            }
            Task { await self.unregisterPrompt(registrationID) }
        }

        return (stream, responseTask)
    }

    /// Removes a finished prompt's event sink from the routing table.
    private func unregisterPrompt(_ id: UUID) {
        promptStreams.removeValue(forKey: id)
    }

    /// Finishes a prompt's event stream once notification routing has been
    /// quiet for a full check interval.
    ///
    /// Why not finish synchronously when the response arrives: swift-acp's
    /// read loop processes wire messages sequentially, yielding every
    /// `session/update` into `client.notifications` strictly *before* resuming
    /// that prompt's response — but Hail consumes the two channels from
    /// independent tasks (`notificationTask` and the prompt's `responseTask`),
    /// and the executor may wake them in either order (swift-acp offers no
    /// inline notification hook, so the producer's ordering is invisible to
    /// consumers). A synchronous `finish()` therefore races the trailing
    /// chunk's route and, when it wins, drops it as a yield-after-finish —
    /// for a short reply that is the whole answer.
    ///
    /// Quiescence is the correct-by-construction signal available: the chunk
    /// was yielded before the response, and `notificationTask` consumes the
    /// stream FIFO, so once routing has been quiet for a full interval after
    /// the response arrived, every pre-response chunk has been routed. The
    /// residual risk is `notificationTask` being starved past one interval
    /// exactly at turn end, which would drop the trailing chunk with this
    /// bounded window instead of the unbounded race it replaces.
    private func finishPromptStreamWhenRoutingSettles(
        _ continuation: AsyncThrowingStream<ACPPromptEvent, Error>.Continuation
    ) async {
        let settleInterval = Duration.milliseconds(25)
        while !Task.isCancelled {
            try? await Task.sleep(for: settleInterval)
            if ContinuousClock.now - lastRoutedAt >= settleInterval { break }
        }
        continuation.finish()
    }

    /// Monitors ACP traffic while a prompt is in flight. After `stallTimeout`
    /// seconds of complete silence, probes the session with a lightweight
    /// `session/list` request:
    ///
    /// - An unresponsive process (probe fails) has its session reset at once,
    ///   failing the pending prompt via `Client.terminate`.
    /// - A responsive process is alive but not necessarily progressing. The
    ///   probe success is *not* treated as activity — the idle clock keeps
    ///   running from the last real ACP notification. Once the turn has been
    ///   silent for `maxStallDuration`, it is failed anyway, so a live-but-
    ///   wedged turn (upstream stall, swallowed error) cannot hang forever.
    private func watchForStall(client: ACP.Client, registrationID: UUID) async {
        // Never check less often than the stall timeout itself, so short
        // timeouts (tests, aggressive configs) are still honored promptly.
        let checkInterval = min(heartbeatInterval, stallTimeout)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(checkInterval))
            guard !Task.isCancelled else { return }
            // The prompt may already be unregistered (finished or cancelled);
            // in that case this watchdog is obsolete.
            guard let lastActivity = promptStreams[registrationID]?.lastActivity else { return }
            let idle = ContinuousClock.now - lastActivity
            guard idle > .seconds(stallTimeout) else { continue }

            // A turn that has produced no ACP traffic for the whole tolerance
            // window is failed whether or not the process still answers pings:
            // liveness is not progress.
            if idle >= .seconds(maxStallDuration) {
                logger.error(
                    "kimi-code turn made no progress within the stall ceiling; resetting so the turn fails",
                    metadata: [
                        "idleSeconds": .string("\(idle.components.seconds)"),
                        "maxStallSeconds": .string("\(Int(maxStallDuration))"),
                    ]
                )
                await reset()
                return
            }

            // Probe with a lightweight request. The timeout is enforced by
            // abandoning the probe, not by the package's own `timeout:`
            // parameter, which cannot fire for an unanswered request: its task
            // group races against a continuation that never resumes. The probe
            // task inherits this actor's isolation, so the flag is a plain
            // local — every access is serialized on the actor already.
            var probeAnswered = false
            let probeTask = Task {
                if (try? await client.listSessions(cwd: workingDirectory)) != nil {
                    probeAnswered = true
                }
            }
            try? await Task.sleep(for: .seconds(probeTimeout))
            if probeAnswered {
                // Alive but silent: keep waiting without touching the idle
                // clock, so the `maxStallDuration` ceiling still applies.
                logger.info(
                    "kimi-code session probe succeeded; turn is slow but alive",
                    metadata: ["idleSeconds": .string("\(idle.components.seconds)")]
                )
            } else {
                probeTask.cancel()
                logger.error(
                    "kimi-code session unresponsive; resetting so the turn fails",
                    metadata: ["idleSeconds": .string("\(idle.components.seconds)")]
                )
                await reset()
                return
            }
        }
    }

    // MARK: - Lifecycle

    private func ensureClient() async throws -> ACP.Client {
        if let client = client {
            return client
        }

        logger.info(
            "Launching kimi-code ACP process",
            metadata: [
                "path": .string(agentPath),
                "args": .string(agentArguments.joined(separator: " ")),
            ]
        )

        let newClient = ACP.Client()
        let delegate = KimiACPClientDelegate(workingDirectory: workingDirectory, authority: activeAuthority)
        self.delegate = delegate
        await newClient.setDelegate(delegate)

        // Spawning the harness is itself a process effect, but it is endpoint
        // infrastructure (fixed binary + arguments from configuration), not a
        // model-decided effect — so it is scoped against the session's
        // creation authority, never the turn's lane.
        try await launchHarness(client: newClient, authority: authority)

        logger.info("ACP process launched, initializing...")
        _ = try await newClient.initialize(
            capabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true
            ),
            timeout: initializeTimeout
        )
        logger.info("ACP client initialized")

        // The single notification consumer for this client's lifetime (see
        // the comment on `notificationTask` above).
        self.notificationTask = Task { [weak self, newClient] in
            for await notification in await newClient.notifications {
                await self?.route(notification: notification)
            }
        }

        self.client = newClient
        return newClient
    }

    /// The harness spawn. Nonisolated from the session actor: it touches only
    /// the immutable launch configuration.
    private func launchHarness(client: ACP.Client, authority: any Authority) async throws {
        try await withEffect(
            ProcessEffect(executable: agentPath, arguments: agentArguments, cwd: workingDirectory),
            authority: authority
        ) { _ in
            try await client.launch(
                agentPath: agentPath,
                arguments: agentArguments,
                workingDirectory: workingDirectory
            )
        }
    }

    /// Routes one ACP notification to the prompt streams registered for its
    /// session. Runs on the actor so `promptStreams` needs no locking.
    private func route(notification: JSONRPCNotification) {
        guard notification.method == "session/update" else { return }
        guard
            let params = notification.params,
            let data = try? JSONEncoder().encode(params),
            let update = try? JSONDecoder().decode(SessionUpdateNotification.self, from: data)
        else {
            logger.debug("dropping undecodable session/update notification")
            return
        }
        lastRoutedAt = .now
        let matchingIDs = promptStreams.keys.filter { promptStreams[$0]?.sessionId == update.sessionId }
        for id in matchingIDs {
            guard let stream = promptStreams[id] else { continue }
            promptStreams[id]?.lastActivity = .now
            switch update.update {
            case .agentMessageChunk(let block):
                if case .text(let textContent) = block {
                    stream.continuation.yield(.text(textContent.text))
                }
            case .agentThoughtChunk(let block):
                if case .text(let textContent) = block {
                    stream.continuation.yield(.thought(textContent.text))
                }
            case .toolCall(let toolCall):
                stream.continuation.yield(.toolCall(toolCall))
            case .toolCallUpdate(let details):
                stream.continuation.yield(.toolCallUpdate(details))
            case .plan(let plan):
                stream.continuation.yield(.plan(plan))
            case .usageUpdate(let usageUpdate):
                stream.continuation.yield(.usage(usageUpdate))
            default:
                break
            }
        }
    }

    private func ensureSession(client: ACP.Client) async throws -> SessionId {
        if let sessionId = sessionId {
            return sessionId
        }

        let mcpServers = await makeMCPServers()
        logger.info(
            "Creating ACP session",
            metadata: ["mcpServers": .string("\(mcpServers.count)")]
        )

        let response = try await client.newSession(
            workingDirectory: workingDirectory,
            mcpServers: mcpServers,
            timeout: newSessionTimeout
        )

        if let modes = response.modes {
            logger.info(
                "ACP session modes",
                metadata: [
                    "currentMode": .string(modes.currentModeId),
                    "availableModes": .string(
                        modes.availableModes.map { "\($0.id):\($0.name)" }.joined(separator: ", ")
                    ),
                ]
            )
        }
        if let configOptions = response.configOptions {
            logger.info(
                "ACP session config options",
                metadata: [
                    "configOptions": .string(
                        configOptions.map { "\($0.id.value) (\($0.name))" }.joined(separator: ", ")
                    )
                ]
            )
        }

        if !model.isEmpty {
            logger.info("Setting ACP model", metadata: ["model": .string(model)])
            let modelName = self.model
            _ = try? await client.setModel(
                sessionId: response.sessionId,
                modelId: modelName
            )
        }

        // Disable thinking for this ACP session only. This keeps the user's
        // global kimi-code config unchanged while making Hail responses
        // faster and less over-planned.
        if let thinkingOption = response.configOptions?.first(where: {
            $0.id.value.lowercased() == "thinking"
                || $0.name.lowercased().contains("thinking")
        }) {
            do {
                _ = try await client.setConfigOption(
                    sessionId: response.sessionId,
                    configId: thinkingOption.id,
                    value: SessionConfigValueId("off")
                )
                logger.info(
                    "Disabled ACP thinking for this session",
                    metadata: ["configId": .string(thinkingOption.id.value)]
                )
            } catch {
                logger.warning(
                    "Failed to disable ACP thinking; session will use global default",
                    metadata: [
                        "configId": .string(thinkingOption.id.value),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        } else {
            logger.info(
                "No thinking config option reported by ACP; using global default",
                metadata: [
                    "availableIDs": .string(
                        response.configOptions?.map { $0.id.value }.joined(separator: ", ") ?? "none"
                    )
                ]
            )
        }

        // Set the session mode to "auto" so tool approvals are handled automatically.
        if let modeOption = response.configOptions?.first(where: {
            $0.id.value.lowercased() == "mode"
        }) {
            do {
                _ = try await client.setConfigOption(
                    sessionId: response.sessionId,
                    configId: modeOption.id,
                    value: SessionConfigValueId("auto")
                )
                logger.info(
                    "Set ACP session mode to auto",
                    metadata: ["configId": .string(modeOption.id.value)]
                )
            } catch {
                logger.warning(
                    "Failed to set ACP session mode to auto",
                    metadata: [
                        "configId": .string(modeOption.id.value),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        } else {
            logger.info(
                "No mode config option reported by ACP; using global default",
                metadata: [
                    "availableIDs": .string(
                        response.configOptions?.map { $0.id.value }.joined(separator: ", ") ?? "none"
                    )
                ]
            )
        }

        logger.info(
            "ACP session ready",
            metadata: ["sessionId": .string(response.sessionId.value)]
        )
        self.sessionId = response.sessionId
        return response.sessionId
    }

    /// Attempts to resume the journaled CLI session via ACP `session/load`.
    /// Returns true when the session was loaded. A resume miss (unknown or
    /// expired session, identity change) leaves the session unset, so the
    /// caller bootstraps a fresh session with the full transcript.
    private func resumeJournaledSession(identity: SessionIdentity) async throws -> Bool {
        guard let resume = resumeSession else { return false }
        resumeSession = nil
        guard resume.identity == identity else {
            logger.info(
                "Journaled ACP session predates a config change; bootstrapping instead",
                metadata: ["sessionId": .string(resume.id.rawValue)]
            )
            return false
        }
        let client = try await ensureClient()
        do {
            _ = try await client.loadSession(
                sessionId: SessionId(resume.id.rawValue),
                cwd: workingDirectory,
                mcpServers: await makeMCPServers()
            )
            sessionId = SessionId(resume.id.rawValue)
            if !model.isEmpty {
                let modelName = model
                _ = try? await client.setModel(sessionId: SessionId(resume.id.rawValue), modelId: modelName)
            }
            logger.info(
                "Resumed ACP session",
                metadata: ["sessionId": .string(resume.id.rawValue)]
            )
            return true
        } catch {
            logger.warning(
                "Could not resume ACP session; falling back to bootstrap",
                metadata: [
                    "sessionId": .string(resume.id.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
            return false
        }
    }

    private func makeMCPServers() async -> [MCPServerConfig] {
        guard let configuration = mcpServerConfiguration else {
            return []
        }
        let env = configuration.environment(agentID: agentID, context: contextLabel)

        return [
            .stdio(
                StdioServerConfig(
                    name: configuration.name,
                    command: configuration.command,
                    args: configuration.arguments,
                    env: env.map { EnvVariable(name: $0.key, value: $0.value) },
                    _meta: nil
                )
            )
        ]
    }

    private func reset() async {
        logger.warning("Resetting ACPSession state")
        for (_, stream) in promptStreams {
            stream.continuation.finish()
        }
        promptStreams.removeAll()
        notificationTask?.cancel()
        notificationTask = nil
        if let client = client {
            await client.terminate()
        }
        client = nil
        delegate = nil
        sessionId = nil
        sessionIdentity = nil
        lastMemorySnapshot = nil
    }

    /// Tears down the live session, terminating the harness process. Called
    /// when the owning agent deactivates; the next prompt cold-starts a new
    /// process and resumes the conversation from the journaled session id.
    func terminate() async {
        await reset()
    }
}
