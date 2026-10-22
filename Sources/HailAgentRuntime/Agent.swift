import AnyLanguageModel
import Distributed
import DistributedCluster
import EventSourcing
import HailCore
import HailModelRuntime
import Logging
import ScopedEffect
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - Agent

/// Explicit result of an attempted passivation.
///
/// The active-agent index is only a liveness projection, so an index outage
/// must not prevent the actor from passivating. `deferred` remains in the
/// public enum for source compatibility with older callers; current runtime
/// code does not use it for directory failures.
public enum AgentDeactivationResult: Sendable, Equatable {
    case active
    case deactivated
    case deferred(String)
}

@EventSourced
@VirtualActor
public distributed actor Agent: AsyncSequence {
    public typealias Event = AgentEvent
    public typealias ActorSystem = ClusterSystem
    public typealias Element = AgentActivity
    public typealias State = AgentState
    /// An agent is activated by identity alone. Its configuration is a host
    /// policy derived from that identity (see
    /// ``AgentRuntimePlugin/SpawnConfigProvider``), so every caller that
    /// addresses the agent activates the same agent, whoever gets there first.
    public typealias Dependency = AgentID

    // Event-sourced state. All mutations happen through `handleEvent`, which
    // delegates to `AgentState.apply(_:)`. Public as an
    // `EventSourced` protocol witness — do not mutate directly.
    public var state: AgentState

    /// Snapshot policy selected by the spawn configuration and interpreted by the
    /// embedding runtime at activation.
    /// Snapshots are a best-effort replay optimization; the journal remains
    /// the source of truth.
    public let snapshotting: Snapshotting<AgentEvent, AgentState>

    // Convenience accessors for the event-sourced state.
    var role: Role { state.agentID.role }
    var contextID: AgentContextID { state.agentID.contextID }

    /// The journaled harness session to resume, if one was recorded.
    private var modelSessionResume: ModelSessionResume? {
        state.modelSession
    }

    // Durable definition plus activation-resolved host capabilities.
    /// The agent's configuration, loaded from the definition journal at
    /// activation (the journal is the truth; nothing caches it). A revived
    /// agent picks up edits made while it was passivated.
    let definition: AgentDefinition
    /// Resolved by the host workspace provider for this activation; never
    /// persisted.
    let workspace: AgentWorkspace
    let agentDirectoryID: AgentDirectoryID
    let interruptedTurns: InterruptedTurns
    /// The host's configuration for this agent's identity. Kept so
    /// ``shouldDeactivate()`` can restore its active-index entry when a turn
    /// starts mid-deactivation — registration otherwise happens only on
    /// activation.
    let spawnConfig: AgentSpawnConfig
    /// The effect authority this agent's tools and harness spawns are scoped
    /// against, resolved once at activation from the runtime plugin's provider.
    let authority: any Authority
    private let _agentID: AgentID

    /// The actor's identity, for observers mapping receptionist guests back to
    /// agent IDs (e.g. the `AgentObserver`).
    public distributed var agentID: AgentID { _agentID }

    // Serializes reasoning turns. Distributed actors are reentrant, so while one
    // turn awaits the model stream another `stream`/`respond` could start a second
    // turn and corrupt the agent's history. Each new turn chains behind the
    // previous one via this actor-isolated task.
    private var processingTask: Task<Void, Never>?
    /// The agent's session, between turns: its scopes, as the last turn left them, for the next
    /// to continue in. A turn holds it while it runs.
    private var session: AgentSession?

    // Ephemeral activity stream (status/thinking/text/tool), shaped like
    // `DistributedSequence`: each subscriber (iterator) carries a stable UUID; the
    // actor parks one continuation per subscriber and fans each fragment out to all
    // of them. Not journaled. A fragment recorded while a subscriber's pull is
    // parked resumes it directly; a fragment recorded between pulls is buffered
    // per subscriber (bounded) and drained on the next pull, so the turn's
    // closing bracket — recorded microseconds after the last progress fragment,
    // long before the subscriber can re-park over a distributed round-trip — is
    // never lost.
    private var activityWaiters: [UUID: CheckedContinuation<AgentActivity?, Never>] = [:]
    private var activityBuffers: [UUID: [AgentActivity]] = [:]

    /// Cap on one subscriber's backlog. Only a subscriber that vanished without
    /// cancelling ever accumulates; the cap bounds that leak. Overflow evicts
    /// the oldest progress fragment first — statuses are transient narration,
    /// superseded by the next one — so turn brackets and display messages
    /// survive even then.
    private static let activityBufferLimit = 128

    public init(actorSystem: ClusterSystem, dependency agentID: AgentID) async throws {
        self.actorSystem = actorSystem
        self._agentID = agentID
        self.state = AgentState(agentID: agentID)
        let spawnConfig = try await actorSystem.agentRuntime.spawnConfig(for: agentID)
        self.snapshotting = await actorSystem.agentRuntime.snapshotting(for: spawnConfig)
        let workspace = try await actorSystem.agentRuntime.workspace(for: spawnConfig)
        // Configuration is supplied by the embedding host. Hail neither knows
        // nor assumes where definitions are persisted.
        let definition = try await actorSystem.agentRuntime.definition(for: spawnConfig)
        self.definition = definition
        self.workspace = workspace
        self.agentDirectoryID = spawnConfig.agentDirectoryID
        self.interruptedTurns = spawnConfig.interruptedTurns
        self.spawnConfig = spawnConfig
        self.authority = await actorSystem.agentRuntime.authority(
            for: spawnConfig,
            workspace: workspace
        )

        // The virtual actor and its event-sourced state share one canonical
        // identity. A separate persistence key could drift and revive the same
        // logical agent with different history.
        try await actorSystem.journal.register(actor: self, with: agentID.rawValue)

        do {
            try await actorSystem.agentRuntime.register(
                entry: AgentDirectoryEntry(
                    agentID: agentID,
                    definition: definition,
                    spawnConfig: spawnConfig
                )
            )
        } catch {
            // The active-agent index is a disposable liveness projection. It
            // must never prevent a durable agent from activating after a
            // singleton restart or temporary directory outage.
            actorSystem.log.warning(
                "Active agent index unavailable during activation",
                metadata: [
                    "agentID": .string(agentID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
        }

        // After replay, a turn that started but never closed was cut off by the crash. The host's
        // policy says whether the agent finishes it or closes it for its driver.
        self.state.normalizeAfterReplay()
        if let turn = state.history.open {
            switch interruptedTurns {
            case .resume:
                let stream = AgentStream<String>(actorSystem: actorSystem)
                Task { [weak self] in
                    guard let self else { return }
                    defer { stream.finish() }
                    do {
                        try await self.whenLocal { agent in
                            try await agent.run(
                                turn.input.content,
                                opening: .resumed(turn),
                                inputID: nil,
                                through: stream.connection,
                                authority: nil
                            )
                        }
                    } catch {
                        actorSystem.log.error(
                            "Interrupted turn replay failed",
                            metadata: [
                                "agentID": .string(agentID.rawValue),
                                "error": .string(String(describing: error)),
                            ]
                        )
                    }
                }
            case .close:
                try await emit(event: .history(.interrupted(at: Date())))
            }
        }

        // The receptionist stores only the actor ID and watches termination by
        // ID, so this registration never pins the actor: it is cleaned up
        // automatically when the actor deinits, and re-registered on respawn.
        await actorSystem.receptionist.checkIn(self, with: Self.agentKey)
    }

    /// The idle sweep's question. Refuses while a turn is in flight — the
    /// question can run mid-suspension of an async turn (reentrancy), so the
    /// answer rests on the journaled domain state (`activeTurn`), never on
    /// mailbox ordering. On accept it also ends the activity stream: parked
    /// subscribers resume with `nil`, their iterations finish, and the
    /// references that would otherwise pin this instance are dropped.
    ///
    /// Acceptance unregisters from the active-agent index, so
    /// `list_agents` stops reporting a passivated agent. The index is only a
    /// discovery projection; it is not consulted when addressing an agent,
    /// and its availability never controls actor lifecycle. Both actions run
    /// before the final `isWorking` re-check; a turn that slips in mid-way
    /// restores the registration.
    public func deactivationResult() async -> AgentDeactivationResult {
        guard !self.isWorking else { return .active }
        do {
            try await actorSystem.agentRuntime.unregister(agentID: state.agentID)
        } catch {
            actorSystem.log.warning(
                "Active agent index unavailable during passivation",
                metadata: [
                    "agentID": .string(state.agentID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
        }
        // Both calls above suspend and this actor is reentrant: a turn that
        // started during either window must not be torn down. The eviction is
        // harmless — the next turn rebuilds the endpoint cold from the
        // journaled session — but an active-index removal must be undone when
        // possible, since registration otherwise happens only on activation.
        // Only after this final check is the commit below (waiter flush +
        // accept) safe.
        guard !self.isWorking else {
            do {
                try await actorSystem.agentRuntime.register(
                    entry: AgentDirectoryEntry(
                        agentID: state.agentID,
                        definition: definition,
                        spawnConfig: spawnConfig
                    )
                )
            } catch {
                actorSystem.log.error(
                    "Failed to restore active agent index entry",
                    metadata: [
                        "agentID": .string(state.agentID.rawValue),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
            return .active
        }
        let waiters = activityWaiters
        activityWaiters.removeAll()
        activityBuffers.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: nil)
        }
        return .deactivated
    }

    /// Compatibility projection for lifecycle callers that only need the
    /// accepted/deferred bit. New code should use ``deactivationResult()``.
    public func shouldDeactivate() async -> Bool {
        if case .deactivated = await deactivationResult() { return true }
        return false
    }

    /// Who said what to the agent, and its work on each: the history hosts read.
    public distributed func history() -> AgentHistory {
        state.history
    }

    public distributed var persistentAgentID: String {
        state.agentID.rawValue
    }

    /// Durable model consumption for dashboards and operators. This is a
    /// projection of journaled request events and is never included in prompts.
    public distributed var usageSummary: AgentUsageSummary {
        state.usageSummary
    }

    /// Latest provider-reported context occupancy for this agent.
    public distributed var latestContextUsage: ContextUsage? {
        state.latestContextUsage
    }

    /// Recent durable model requests for a dashboard. Complete history can be
    /// projected from journal events with ``AgentJournalReader``.
    public distributed var modelRequests: [ModelRequestRecord] {
        state.modelRequests
    }

    /// Coarse current state for operators; streamed text and reasoning remain
    /// available through the activity sequence.
    public distributed var statusSnapshot: AgentStatusSnapshot {
        return AgentStatusSnapshot(
            agentID: state.agentID,
            state: state.runtimeState,
            contextUsage: state.latestContextUsage
        )
    }

    /// A consistent, read-only diagnostics projection for context commands and
    /// operator dashboards. It is assembled inside the event-sourced actor so
    /// all values describe the same state revision.
    public distributed var contextSnapshot: AgentContextSnapshot {
        return AgentContextSnapshot(
            agentID: state.agentID,
            state: state.runtimeState,
            contextUsage: state.latestContextUsage,
            usageSummary: state.usageSummary,
            recentModelRequestCount: state.modelRequests.count,
            historyTurnCount: state.history.closed.count + (state.history.open == nil ? 0 : 1),
            hasContextSummary: state.history.earlier != nil
        )
    }

    // MARK: - Distributed API

    /// Runs one streaming turn for a captured turn input. Live updates and the final
    /// response are delivered through the provided connection.
    ///
    /// The final generated value is emitted as a
    /// `.responseRecorded` update on the connection; callers that only need the
    /// final result use ``respond(_:)`` instead.
    ///
    /// `authority` pins the turn to an effect lane (e.g. ``TurnAuthorityLane/untrustedInput``);
    /// `nil` runs the turn under the agent's plugin-derived authority. The lane
    /// is a per-turn value: the agent's default tool registry and future turns
    /// are unaffected.
    public distributed func stream<Input: Codable & Sendable, Output>(
        _ input: Input,
        received: AgentHistory.Input,
        inputID: String? = nil,
        through connection: AgentConnection<Output>,
        authority lane: TurnAuthorityLane? = nil
    ) async throws
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        try await run(
            input, opening: .received(received), inputID: inputID,
            through: connection, authority: lane)
    }

    /// Runs one turn after the one before it: the history's turns come in order. The loop
    /// records how it opens and how it ends; a turn left open is one a crash interrupted.
    private func run<Input: Codable & Sendable, Output>(
        _ input: Input,
        opening: TurnOpening,
        inputID: String?,
        through connection: AgentConnection<Output>,
        authority lane: TurnAuthorityLane?
    ) async throws
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let previousTask = processingTask
        let turnID: TurnID =
            switch opening {
            case .received: TurnID()
            case .resumed(let turn): turn.id
            }
        let workTask = Task<Void, Error> { [input, connection] in
            await previousTask?.value
            let loop = await self.reasoningLoop(lane: lane, turnID: turnID)
            recordActivity(.turn(.started, at: Date()))
            defer { recordActivity(.turn(.completed, at: Date())) }
            do {
                try await loop.run(
                    input,
                    opening: opening,

                    inputID: inputID,
                    through: connection
                )
            } catch let loopError as ReasoningLoopError {
                switch loopError {
                case .failureNotEmitted(let runtimeError), .failed(let runtimeError):
                    throw runtimeError
                }
            }
        }
        // Chain a fire-and-forget task so the next turn waits for this one
        // regardless of whether the caller awaits the result. After the turn, the history is
        // compacted if the context is past the threshold: the caller has its answer already, and
        // the next turn waits for it.
        processingTask = Task<Void, Never> { [workTask] in
            _ = try? await workTask.value
            await self.reasoningLoop(lane: lane).compactAfterTurn()
        }
        // The turn runs in a task of its own, so the next waits for it; its caller's cancellation
        // reaches it all the same, as it reaches any call the caller awaits.
        try await withTaskCancellationHandler {
            try await workTask.value
        } onCancel: {
            workTask.cancel()
        }
    }

    /// Runs a structured turn and returns the final typed value.
    ///
    /// This is a convenience over ``stream(_:through:)`` that ignores live
    /// updates and returns only the final result. `authority` pins the turn to
    /// an effect lane, exactly as in ``stream(_:through:authority:)``.
    public distributed func respond<Input: Codable & Sendable, Output>(
        _ input: Input,
        received: AgentHistory.Input,
        inputID: String? = nil,
        authority lane: TurnAuthorityLane? = nil
    ) async throws -> Output
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let stream = AgentStream<Output>(actorSystem: actorSystem)
        defer { stream.finish() }

        let responseTask = Task<Output?, Error> {
            var result: Output?
            for await update in stream.updates {
                if case .responseRecorded(let content, _) = update {
                    result = content
                }
            }
            return result
        }

        try await self.stream(
            input,
            received: received,

            inputID: inputID,
            through: stream.connection,
            authority: lane
        )
        stream.finish()

        guard let outcome = try await responseTask.value else {
            throw AgentRuntimeError.modelMisbehavior("Structured turn produced no typed outcome")
        }
        return outcome
    }

    /// Whether a turn is open on this actor: the live signal the `AgentObserver` uses.
    public distributed var isWorking: Bool {
        state.history.open != nil
    }

    // MARK: Activity stream

    /// Records an externally reported status line onto the activity stream (the
    /// `report_status` tool sink). Ephemeral — not journaled.
    public distributed func recordStatusActivity(_ message: String, at: Date) async {
        recordActivity(.turn(.progress(.status(GeneratedContent(message))), at: at))
    }

    /// Resumes the subscriber with the next activity fragment: a buffered one
    /// if fragments were recorded while it was between pulls, otherwise parks
    /// until the next fragment is published. Mirrors
    /// `DistributedSequence.getNext(_:)`; the subscriber identity is the
    /// iterator's stable UUID. The first pull registers the subscriber — only
    /// registered subscribers accumulate a backlog.
    public distributed func getNext(_ subscriber: UUID) async -> AgentActivity? {
        if var buffer = activityBuffers[subscriber], !buffer.isEmpty {
            let next = buffer.removeFirst()
            activityBuffers[subscriber] = buffer
            return next
        }
        if activityBuffers[subscriber] == nil {
            activityBuffers[subscriber] = []
        }
        return await withCheckedContinuation { self.activityWaiters[subscriber] = $0 }
    }

    /// Tears down the subscriber, resuming any parked pull with `nil` and
    /// dropping its backlog. Idempotent.
    public distributed func cancel(_ subscriber: UUID) {
        activityBuffers.removeValue(forKey: subscriber)
        guard let waiter = activityWaiters.removeValue(forKey: subscriber) else { return }
        waiter.resume(returning: nil)
    }

    // MARK: - AsyncSequence

    /// Activity streaming shaped like `DistributedSequence`: consumers
    /// `for await activity in agent`, each iteration pulling one fragment.
    public nonisolated func makeAsyncIterator() -> ActivityIterator {
        ActivityIterator(ref: self)
    }

    public final class ActivityIterator: AsyncIteratorProtocol {
        /// Weak by design: the subscription must not keep the agent alive at
        /// rest. A parked pull pins only for the duration of the in-flight
        /// call; a deactivated agent ends the stream with `nil`, the same
        /// shape as the `shouldDeactivate()` flush.
        private weak var ref: Agent?
        private let uuid: UUID = UUID()

        init(ref: Agent) {
            self.ref = ref
        }

        /// Cancellation-aware pull: a consumer whose task is cancelled (chat
        /// closed, shutdown) unplugs itself immediately instead of staying
        /// parked in `activityWaiters` and pinning the agent.
        public func next() async -> AgentActivity? {
            if Task.isCancelled { return nil }
            guard let ref else { return nil }
            return await withTaskCancellationHandler { [ref, uuid] in
                try? await ref.getNext(uuid)
            } onCancel: { [ref, uuid] in
                Task.detached { try? await ref.cancel(uuid) }
            }
        }

        deinit {
            let ref = ref
            let uuid = uuid
            Task.detached { try? await ref?.cancel(uuid) }
        }
    }

    private func recordActivity(_ activity: AgentActivity) {
        // Fan the fragment out to every parked subscriber; a registered
        // subscriber between pulls (not parked) picks it up from its backlog
        // on the next pull instead. Without the backlog the turn's closing
        // bracket — recorded immediately after the last progress fragment —
        // would outrun the subscriber's re-park round-trip and consumers
        // would never learn the turn ended.
        let waiters = activityWaiters
        activityWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: activity)
        }
        let unparked = activityBuffers.keys.filter { waiters[$0] == nil }
        for subscriber in unparked {
            append(activity, toBacklogOf: subscriber)
        }
    }

    private func append(_ activity: AgentActivity, toBacklogOf subscriber: UUID) {
        activityBuffers[subscriber, default: []].append(activity)
        guard var buffer = activityBuffers[subscriber], buffer.count > Self.activityBufferLimit else { return }
        if let progressIndex = buffer.firstIndex(where: {
            if case .turn(.progress, _) = $0 { return true }
            return false
        }) {
            buffer.remove(at: progressIndex)
        } else {
            buffer.removeFirst()
        }
        activityBuffers[subscriber] = buffer
    }

    /// Applies a journaled event. Events are checked against the state before they're journaled
    /// (``emitReasoningEvent(_:)``), so one the state can't take means the journal isn't this
    /// agent's: replay stops there, loudly.
    public func handleEvent(_ event: AgentEvent) {
        do {
            try state.apply(event)
        } catch {
            preconditionFailure("Journal of \(state.agentID.rawValue) has an event its history can't take: \(error)")
        }
    }

    /// Adapts the event-sourcing API to the typed event port consumed by
    /// ``ReasoningLoop``. Infrastructure errors are translated once here;
    /// the loop cannot accidentally leak a raw storage failure.
    private func emitReasoningEvent(_ event: AgentEvent) async throws(AgentRuntimeError) {
        do {
            _ = try state.applying(event)
        } catch {
            throw AgentRuntimeError.invalidHistory(error)
        }
        do {
            try await emit(event: event)
        } catch {
            if error is CancellationError {
                throw AgentRuntimeError.cancelled
            }
            if let runtimeError = error as? AgentRuntimeError {
                throw runtimeError
            }
            throw AgentRuntimeError.persistenceFailure(
                "Could not record agent event: \(error)"
            )
        }
    }

    // MARK: - Reasoning loop host

    /// The reasoning loop this actor hosts. Built per access from stable,
    /// activation-scoped dependencies; the closures hop back onto this actor,
    /// so turns keep journaling and activity streaming through this instance.
    ///
    /// `lane` is the per-turn effect lane: its authority flows into the turn's
    /// tool registry and the session-owning endpoint's stream call. `nil`
    /// keeps the agent's plugin-derived authority and rebuilds turn resources.
    ///
    /// LANE-AUTHORITY INVARIANT: the endpoint is deliberately resolved with
    /// the agent's default authority even for a laned turn. That creation
    /// authority scopes only endpoint *infrastructure* — the harness process
    /// spawn — which must stay broad so a deny-everything lane (e.g.
    /// ``TurnAuthorityLane/untrustedInput``) can still run a turn at all. The
    /// lane's authority reaches the turn per-stream instead:
    /// `ReasoningLoop.authority` is handed to
    /// ``SessionOwningEndpoint/stream(messages:delta:authority:tools:responseType:)``
    /// on every turn, and every session-owning endpoint honors it for
    /// *model-facing* effects (the ACP delegate's fs/terminal checks, Codex's
    /// approval decisions); Hail-side tools run through the laned registry.
    /// Endpoint creation is scoped to the turn, so no provider resource can
    /// carry authority or configuration across turns accidentally.
    private func reasoningLoop(
        lane: TurnAuthorityLane?,
        turnID: TurnID = TurnID()
    ) async -> ReasoningLoop<ContinuousClock> {
        let turnAuthority: any Authority
        if let laneAuthority = lane?.authority {
            turnAuthority = laneAuthority
        } else {
            turnAuthority = await actorSystem.agentRuntime.authority(
                for: spawnConfig,
                workspace: workspace
            )
        }
        return ReasoningLoop<ContinuousClock>(
            agentID: state.agentID,
            turnID: turnID,
            logger: actorSystem.log,
            authority: turnAuthority,
            context: { () async throws(AgentRuntimeError) -> TurnContext in
                try await self.buildTurnContext()
            },
            rebuildContext: { (snapshot: TurnContext) async throws(AgentRuntimeError) -> TurnContext in
                try await self.buildTurnContext(reusing: snapshot)
            },
            endpoint: { turnContext async throws(AgentRuntimeError) -> any ModelEndpoint in
                let modelConfiguration = turnContext.promptContext.modelConfiguration
                // Creation authority is the agent's default on purpose — it
                // scopes only the harness spawn (see the invariant above);
                // the lane's authority reaches the endpoint per-stream via
                // the loop's `authority`.
                do {
                    return try await self.actorSystem.agentRuntime.endpoint(
                        for: modelConfiguration.model.identifier,
                        agentID: self.state.agentID,
                        workspace: self.workspace,
                        executionPolicy: turnContext.promptContext.definition.behavior.execution,
                        resumeSession: turnContext.modelSession,
                        authority: turnAuthority,
                        reasoningEffort: modelConfiguration.reasoningEffort
                    )
                } catch {
                    throw Self.mapEndpointDependencyError(error)
                }
            },
            modelReasoningPolicy: actorSystem.agentRuntime.modelReasoningPolicy,
            session: { (turnContext: AgentTurnContext) async throws(AgentRuntimeError) -> AgentSession in
                try await self.takeSession(
                    lane: lane,
                    defaultAuthority: turnAuthority,
                    turnContext: turnContext
                )
            },
            keepSession: { await self.keep($0) },
            emit: { (event: AgentEvent) async throws(AgentRuntimeError) in
                try await self.emitReasoningEvent(event)
            },
            recordActivity: { await self.recordActivity($0) },
            compactor: actorSystem.agentRuntime.contextCompactor,
            compactionOperation: actorSystem.agentRuntime.compactionOperation,
            assemblePrompt: actorSystem.agentRuntime.assemblePrompt,
            clock: ContinuousClock(),
            maxToolRounds: actorSystem.agentRuntime.maxToolRounds
        )
    }

    private func buildTurnContext(
        reusing snapshot: TurnContext? = nil
    ) async throws(AgentRuntimeError) -> TurnContext {
        let runtime = actorSystem.agentRuntime
        let assemblePrompt = runtime.assemblePrompt
        let agentID: AgentID
        let definition: AgentDefinition
        let contextManifest: ContextManifest
        let instructions: PromptAssemblyInstructions
        let sessionIdentity: SessionIdentity
        let modelSession: ModelSessionResume?
        let modelConfiguration: ModelConfiguration

        if let snapshot {
            // A turn owns these inputs for its entire lifetime. Only the
            // journal-derived history and summary below are refreshed.
            agentID = snapshot.promptContext.agentID
            definition = snapshot.promptContext.definition
            contextManifest = snapshot.promptContext.contextManifest
            instructions = snapshot.promptContext.instructions
            sessionIdentity = snapshot.sessionIdentity
            modelSession = snapshot.modelSession
            modelConfiguration = snapshot.promptContext.modelConfiguration
        } else {
            do {
                contextManifest =
                    try await runtime.contextProvider?.manifest(state.agentID, actorSystem)
                    ?? ContextManifest(items: [])
            } catch {
                throw mapInfrastructureDependencyError(
                    error,
                    operation: "Could not build model context"
                )
            }
            agentID = state.agentID
            // Resolve host-owned agent configuration at the turn boundary.
            // The resulting definition is retained in this TurnContext so
            // edits made while the turn is running cannot mix configuration
            // across model rounds, tool calls, or compaction.
            do {
                definition = try await runtime.definition(for: self.spawnConfig)
            } catch {
                throw mapInfrastructureDependencyError(
                    error,
                    operation: "Could not resolve agent configuration"
                )
            }
            instructions = runtime.promptInstructions
            modelConfiguration = try await runtime.modelConfiguration(for: state.agentID)
            sessionIdentity = AgentSessionIdentity.fingerprint(
                model: modelConfiguration.model.identifier,
                reasoningEffort: modelConfiguration.reasoningEffort,
                systemPrompt: definition.behavior.systemPrompt,
                personaInstructions: definition.persona?.instructions,
                configurationIdentity: modelConfiguration.sessionConfigurationIdentity
            )
            let persistedSession = self.modelSessionResume
            modelSession = persistedSession?.identity == sessionIdentity ? persistedSession : nil
        }

        let promptContext = PromptContext(
            agentID: agentID,
            definition: definition,
            modelConfiguration: modelConfiguration,
            history: state.history,
            contextManifest: contextManifest,
            instructions: instructions
        )
        return TurnContext(
            preparedRequest: assemblePrompt(promptContext),
            promptContext: promptContext,
            sessionIdentity: sessionIdentity,
            modelSession: modelSession,
            latestContextUsage: state.latestContextUsage
        )
    }

    /// The tool registry for one turn, built fresh on every turn: host tools
    /// derive from the current turn context, and a
    /// cache of journaled state is a staleness bug in a distributed world —
    /// a tool registered while this agent was idle must appear on its very
    /// next turn. Rebuilding is cheap: value-type tool construction plus the
    /// providers' journal replays, against turns that are seconds apart.
    /// A laned turn builds under the lane's authority, an unlaned one under
    /// the agent's plugin-derived authority.
    private func takeSession(
        lane: TurnAuthorityLane?,
        defaultAuthority: any Authority,
        turnContext: AgentTurnContext
    ) async throws(AgentRuntimeError) -> AgentSession {
        // The turn holds the agent's session while it runs, under this turn's authority and tools.
        var session = self.session.take() ?? AgentSession()
        session.authority = lane?.authority ?? defaultAuthority
        try await registerTools(in: &session, turnContext: turnContext)
        return session
    }

    /// Takes the agent's session back from a turn that ended.
    private func keep(_ session: consuming AgentSession) {
        self.session = consume session
    }

    /// Registers the host's turn tools into the turn's `scope`. Runs once per turn
    /// (see ``takeSession(lane:defaultAuthority:turnContext:)``).
    private func registerTools(
        in session: inout AgentSession,
        turnContext: AgentTurnContext
    ) async throws(AgentRuntimeError) {
        let runtime = actorSystem.agentRuntime
        let turnTools: TurnTools
        do {
            turnTools = try await runtime.turnTools(
                for: turnContext,
                actorSystem: actorSystem
            )
        } catch {
            throw mapInfrastructureDependencyError(error, operation: "Could not load agent tools")
        }
        session.offer(turnTools)
    }

    private static func mapEndpointDependencyError(_ error: any Error) -> AgentRuntimeError {
        if error is CancellationError { return .cancelled }
        if let runtimeError = error as? AgentRuntimeError { return runtimeError }
        return .configurationError("Could not resolve model endpoint: \(error)")
    }

    private func mapInfrastructureDependencyError(
        _ error: any Error,
        operation: String
    ) -> AgentRuntimeError {
        if error is CancellationError { return .cancelled }
        if let runtimeError = error as? AgentRuntimeError { return runtimeError }
        return .infrastructureFailure("\(operation): \(error)")
    }

}

extension ClusterSystem {
    /// The agent with this identity, activating it if it is idle.
    ///
    /// Prefer this over `virtualActors.getActor`: that API is generic over
    /// the dependency, so passing anything but an `AgentID` compiles and
    /// fails only at activation. Here the identity is the only input, as it
    /// must be — an agent's configuration is the host's policy over its id
    /// (see ``AgentRuntimePlugin/SpawnConfigProvider``).
    public func agent(_ agentID: AgentID) async throws -> Agent {
        try await virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: agentID.rawValue),
            dependency: agentID
        )
    }
}

extension Agent {
    /// Receptionist key for dynamically spawned agents. Registration is by
    /// actor ID only, so it does not keep the actor alive.
    public static var agentKey: DistributedReception.Key<Agent> {
        "agent-key"
    }
}
