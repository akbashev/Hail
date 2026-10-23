import DistributedCluster
import EventSourcing
import Foundation
import HailCore
import HailModelRuntime
import ScopedEffect

// MARK: - Directory entry

public struct AgentDirectoryEntry: Codable, Sendable {
    public let agentID: AgentID
    public let role: Role
    public let definition: AgentDefinition?
    /// Spawn config the agent was activated with, so any caller can resolve and
    /// reach it by `AgentID` (e.g. to subscribe to its activity stream).
    public let spawnConfig: AgentSpawnConfig?

    public init(
        agentID: AgentID,
        definition: AgentDefinition? = nil,
        spawnConfig: AgentSpawnConfig? = nil
    ) {
        self.agentID = agentID
        self.role = agentID.role
        self.definition = definition
        self.spawnConfig = spawnConfig
    }
}

public enum AgentDirectoryError: Error, Sendable, Equatable {
    case unavailable
}

public enum AgentRuntimeConfigurationError: Error, Sendable, Equatable {
    case invalidMaxToolRounds(Int)
}

// MARK: - Active-agent index

/// A cluster singleton that holds the in-memory active-agent directory.
///
/// This is deliberately a liveness index, not a durable existence catalog:
/// passivation removes an entry, and a process/node restart may temporarily
/// lose entries until actors activate and register again. Durable agent state
/// remains in each agent's event journal. It is used for active-agent
/// discovery and observability only; actor routing and lifecycle do not depend
/// on it.
public distributed actor ActiveAgentIndex: ClusterSingleton {
    private var entries: [AgentID: AgentDirectoryEntry] = [:]

    public distributed func register(entry: AgentDirectoryEntry) {
        self.entries[entry.agentID] = entry
    }

    public distributed func unregister(agentID: AgentID) {
        self.entries.removeValue(forKey: agentID)
    }

    public distributed func entry(forAgentID agentID: AgentID) -> AgentDirectoryEntry? {
        self.entries[agentID]
    }

    public distributed func agents(ofType role: Role) -> [AgentDirectoryEntry] {
        self.entries.values.filter { $0.role == role }
    }

    public distributed func allAgents() -> [AgentDirectoryEntry] {
        Array(self.entries.values)
    }
}

// MARK: - Runtime plugin

/// The single cluster plugin that hosts the active-agent index, resolves model
/// endpoints, and delegates tool injection and prompt strategy to configurable
/// closures.
///
/// A host configures these closures at bootstrap, keeping product-specific
/// persistence, tools, and policy outside Hail.
public actor AgentRuntimePlugin: ActorLifecyclePlugin {
    /// Selects the event-sourcing snapshot policy for one agent activation.
    /// Keeping this in the runtime plugin lets hosts choose cadence and
    /// retention without putting executable closures into `AgentSpawnConfig`.
    public typealias SnapshottingProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig) -> Snapshotting<AgentEvent, AgentState>

    public typealias TurnToolsProvider =
        @Sendable (
            _ context: AgentTurnContext,
            _ actorSystem: ClusterSystem
        ) async throws -> TurnTools

    /// Derives the effect ``Authority`` for one agent from its durable spawn
    /// intent and activation-resolved workspace. The authority — a value of
    /// closures — is resolved here instead of riding on the `Codable` config.
    public typealias AuthorityProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig, _ workspace: AgentWorkspace) async -> any Authority

    /// Derives an agent's configuration from its identity. An agent is
    /// activated by `AgentID` alone — by its owner, another agent messaging
    /// it, or a dashboard reading it — so its configuration must be a host
    /// policy over that identity, never data an activating caller supplies:
    /// otherwise whichever caller happens to activate it first decides how it
    /// is built.
    public typealias SpawnConfigProvider =
        @Sendable (_ agentID: AgentID) async throws(AgentRuntimeError) -> AgentSpawnConfig

    /// Resolves the host's physical workspace for an agent's logical scope.
    /// The result is activation-time state and is never persisted with the
    /// distributed spawn config.
    public typealias WorkspaceProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig) async throws(AgentRuntimeError) -> AgentWorkspace

    /// Loads a definition from the host's chosen configuration store. Returning
    /// `nil` selects Hail's generic role default.
    public typealias DefinitionProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig) async throws -> AgentDefinition?

    public static let pluginKey: Key = "$agentRuntime"

    public nonisolated var key: Key {
        Self.pluginKey
    }

    private var actorSystem: ClusterSystem!
    private var activeAgentIndex: ActiveAgentIndex?
    private let deliveryTracker: AgentDeliveryTracker
    private let modelRouter: ModelRouter
    /// Host-selected ceiling on tool-call rounds within a single turn.
    /// There is intentionally no runtime fallback: this is an application
    /// safety policy supplied at composition time.
    public let maxToolRounds: Int

    /// Host policy for per-request reasoning overrides. It receives only
    /// structured turn state; prompt-language classification belongs to the
    /// host, if a host chooses to add it at all.
    public let modelReasoningPolicy: ModelReasoningPolicy

    /// Optional closure that returns the host's tools for one turn.
    /// Invoked once per turn after the input has been normalized to a
    /// ``AgentTurnContext``. Tool construction should be cheap and
    /// side-effect-free: value construction is fine, network calls are not.
    public var turnToolsProvider: TurnToolsProvider?

    /// Optional closure that derives an agent's effect authority. When nil,
    /// file effects are pinned to the agent's workspace and everything else
    /// is open (``CompositeAuthority/workspaceDefault(root:)``).
    public var authorityProvider: AuthorityProvider?

    public let workspaceProvider: WorkspaceProvider

    public let spawnConfigProvider: SpawnConfigProvider

    public var definitionProvider: DefinitionProvider?

    /// Host-owned model selection for each turn. A new configuration is
    /// resolved before every turn, so application model changes take effect
    /// without replacing the durable agent.
    public let modelSelectionProvider: ModelSelectionProvider

    /// Pure transformation that assembles an agent's model request.
    public let assemblePrompt: PromptAssembler

    /// Product/host instructions rendered by the standard assembler. The
    /// runtime supplies structure and context; the host owns its task rules.
    public let promptInstructions: PromptAssemblyInstructions

    /// Optional compactor: consulted before requests, its result is journaled
    /// as one `compacted` conversation event.
    public let contextCompactor: (any ContextCompactor)?

    /// Optional host-defined typed report generation for compaction.
    public let compactionOperation: CompactionOperation?

    /// Host-selected executable snapshot policy. The default interprets the
    /// serializable policy in ``AgentSpawnConfig``; hosts may inject a custom
    /// provider for rules that cannot be represented by that value.
    public let snapshottingProvider: SnapshottingProvider

    /// Provider that resolves external context documents for an agent turn.
    /// When nil, the runtime falls back to inline context.
    public let contextProvider: AgentContextProvider?

    public init(
        maxToolRounds: Int,
        routerConfiguration: ModelRouterConfiguration,
        modelEndpointProvider: ModelEndpointProvider? = nil,
        turnToolsProvider: TurnToolsProvider? = nil,
        authorityProvider: AuthorityProvider? = nil,
        workspaceProvider: @escaping WorkspaceProvider,
        spawnConfigProvider: @escaping SpawnConfigProvider = { AgentSpawnConfig(agentID: $0) },
        definitionProvider: DefinitionProvider? = nil,
        modelSelectionProvider: @escaping ModelSelectionProvider,
        contextProvider: AgentContextProvider? = nil,
        contextCompactor: (any ContextCompactor)? = nil,
        compactionOperation: CompactionOperation? = nil,
        snapshottingProvider: @escaping SnapshottingProvider = { spawnConfig in
            AgentRuntimePlugin.defaultSnapshotting(for: spawnConfig.snapshotPolicy)
        },
        promptInstructions: PromptAssemblyInstructions = PromptAssemblyInstructions(),
        assemblePrompt: @escaping PromptAssembler = assembleStandardPrompt,
        modelReasoningPolicy: @escaping ModelReasoningPolicy = { _ in .providerDefault }
    ) throws(AgentRuntimeConfigurationError) {
        guard maxToolRounds > 0 else {
            throw .invalidMaxToolRounds(maxToolRounds)
        }
        self.modelRouter = ModelRouter(
            configuration: routerConfiguration,
            modelEndpointProvider: modelEndpointProvider
        )
        self.deliveryTracker = AgentDeliveryTracker()
        self.maxToolRounds = maxToolRounds
        self.modelReasoningPolicy = modelReasoningPolicy
        self.turnToolsProvider = turnToolsProvider
        self.authorityProvider = authorityProvider
        self.workspaceProvider = workspaceProvider
        self.spawnConfigProvider = spawnConfigProvider
        self.definitionProvider = definitionProvider
        self.modelSelectionProvider = modelSelectionProvider
        self.contextProvider = contextProvider
        self.contextCompactor = contextCompactor
        self.compactionOperation = compactionOperation
        self.snapshottingProvider = snapshottingProvider
        self.promptInstructions = promptInstructions
        self.assemblePrompt = assemblePrompt
    }

    public func snapshotting(
        for spawnConfig: AgentSpawnConfig
    ) -> Snapshotting<AgentEvent, AgentState> {
        snapshottingProvider(spawnConfig)
    }

    /// Translates the Codable spawn intent into the executable event-sourcing
    /// policy. This is the only place where Hail's compaction event is coupled
    /// to the generic snapshotting predicate.
    public static func defaultSnapshotting(
        for policy: AgentSnapshotPolicy
    ) -> Snapshotting<AgentEvent, AgentState> {
        switch policy {
        case .disabled:
            return .disabled

        case .periodic(let every, let retention):
            return .every(
                numberOfEvents: max(1, every),
                retention: retentionCriteria(for: retention)
            )

        case .periodicOrWhenCompacted(let every, let retention):
            return .every(
                numberOfEvents: max(1, every),
                retention: retentionCriteria(for: retention),
                orWhen: snapshotOnCompaction
            )

        case .whenCompacted:
            return .when(snapshotOnCompaction)
        }
    }

    private static let snapshotOnCompaction: @Sendable (AgentEvent, AgentState, Int64) -> Bool = { event, _, _ in
        if case .history(.compacted) = event { return true }
        return false
    }

    private static func retentionCriteria(
        for retention: AgentSnapshotRetention
    ) -> RetentionCriteria {
        switch retention {
        case .keepAll:
            return .keepAll
        case .keepLast(let count):
            return .keepLast(max(1, count))
        }
    }

    /// The host's configuration for one agent identity.
    public func spawnConfig(for agentID: AgentID) async throws(AgentRuntimeError) -> AgentSpawnConfig {
        let config = try await spawnConfigProvider(agentID)
        guard config.agentID == agentID else {
            throw .configurationError(
                "Spawn config provider returned '\(config.agentID)' for '\(agentID)'"
            )
        }
        return config
    }

    /// Resolves the host workspace for one activation.
    public func workspace(for spawnConfig: AgentSpawnConfig) async throws(AgentRuntimeError) -> AgentWorkspace {
        let workspace = try await workspaceProvider(spawnConfig)
        guard !workspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .configurationError("Workspace provider returned an empty root")
        }
        return workspace
    }

    /// Resolves the effect authority for one agent. Defaults to
    /// ``CompositeAuthority/workspaceDefault(root:)`` — file effects pinned
    /// to the resolved workspace, everything else open.
    public func authority(
        for spawnConfig: AgentSpawnConfig,
        workspace: AgentWorkspace
    ) async -> any Authority {
        await authorityProvider?(spawnConfig, workspace)
            ?? CompositeAuthority.workspaceDefault(root: workspace.rootPath)
    }

    public func definition(for spawnConfig: AgentSpawnConfig) async throws -> AgentDefinition {
        try await definitionProvider?(spawnConfig)
            ?? .defaultDefinition(for: spawnConfig.agentID.role)
    }

    public func modelConfiguration(
        for agentID: AgentID
    ) async throws(AgentRuntimeError) -> ModelConfiguration {
        do {
            return try await modelSelectionProvider(
                ModelSelectionRequest(
                    agentID: agentID
                )
            )
        } catch {
            throw .configurationError(
                "Could not resolve model configuration: \(error)"
            )
        }
    }

    // MARK: Model endpoints

    /// Creates the endpoint for one execution turn. The endpoint is not
    /// retained by the runtime.
    public func endpoint(
        for model: String,
        agentID: AgentID,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        try await modelRouter.endpoint(
            for: model,
            agentID: agentID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            authority: authority,
            reasoningEffort: reasoningEffort
        )
    }

    // MARK: Agent directory

    /// Adds an active-agent entry to the liveness index. Failure means the
    /// index is unavailable; it does not mean the agent failed to activate.
    public func register(entry: AgentDirectoryEntry) async throws {
        guard let activeAgentIndex else { throw AgentDirectoryError.unavailable }
        try await activeAgentIndex.register(entry: entry)
    }

    /// Removes an active-agent entry from the liveness index. Failure should be
    /// treated as stale discovery data, not as a lifecycle veto.
    public func unregister(agentID: AgentID) async throws {
        guard let activeAgentIndex else { throw AgentDirectoryError.unavailable }
        try await activeAgentIndex.unregister(agentID: agentID)
    }

    /// Returns an active-agent entry, if the liveness index currently knows it.
    /// A `nil` result is not an existence check for the durable agent.
    public func entry(forAgentID agentID: AgentID) async throws -> AgentDirectoryEntry? {
        guard let activeAgentIndex else { throw AgentDirectoryError.unavailable }
        return try await activeAgentIndex.entry(forAgentID: agentID)
    }

    public func agents(ofType role: Role) async throws -> [AgentDirectoryEntry] {
        guard let activeAgentIndex else { throw AgentDirectoryError.unavailable }
        return try await activeAgentIndex.agents(ofType: role)
    }

    /// Lists currently active agents. Passivated or not-yet-reactivated agents
    /// are intentionally absent.
    public func allAgents() async throws -> [AgentDirectoryEntry] {
        guard let activeAgentIndex else { throw AgentDirectoryError.unavailable }
        return try await activeAgentIndex.allAgents()
    }

    // MARK: Agent delivery

    /// Accepts a best-effort, process-local asynchronous delivery. The
    /// operation is tracked until it completes or fails; it is not persisted
    /// and may be lost if this process exits.
    public func enqueueDelivery(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> AgentDeliveryID {
        await deliveryTracker.enqueue(operation)
    }

    public func deliveryStatus(for id: AgentDeliveryID) async -> AgentDeliveryStatus? {
        await deliveryTracker.status(for: id)
    }

    public func activeDeliveryCount() async -> Int {
        await deliveryTracker.activeDeliveryCount()
    }

    // MARK: Tool injection

    /// Returns the tools for one turn: the host's, or, without a provider,
    /// Hail's own ``agentTools(for:actorSystem:)``. An agent is offered only
    /// what's here, so a host includes Hail's tools only where it grants them.
    public func turnTools(
        for context: AgentTurnContext,
        actorSystem: ClusterSystem
    ) async throws -> TurnTools {
        guard let turnToolsProvider else {
            return TurnTools(tools: try await agentTools(for: context, actorSystem: actorSystem))
        }
        return try await turnToolsProvider(context, actorSystem)
    }

    /// Hail's own tools for the agent of `context`: the time, the files in
    /// its workspace, and messaging other agents.
    public func agentTools(
        for context: AgentTurnContext,
        actorSystem: ClusterSystem
    ) async throws(AgentRuntimeError) -> [any Tool] {
        let workspace = try await workspace(for: try await spawnConfig(for: context.agentID))
        return [
            NowTool(),
            FileTool(projectRoot: URL(fileURLWithPath: workspace.rootPath)),
            AgentTool(sourceAgentID: context.agentID, system: actorSystem),
        ]
    }

    // MARK: Lifecycle hooks

    public func start(_ system: ClusterSystem) async throws {
        self.actorSystem = system
        self.activeAgentIndex = try await system.singleton.host(name: "\(Self.pluginKey)_active_index") {
            ActiveAgentIndex(actorSystem: $0)
        }
    }

    public func stop(_ system: ClusterSystem) async {
        await deliveryTracker.cancelAll()
        self.activeAgentIndex = nil
        self.actorSystem = nil
    }

    nonisolated public func onActorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {}

    nonisolated public func onResignID(_ id: DistributedCluster.ClusterSystem.ActorID) {}
}

// MARK: - Cluster system access

extension ClusterSystem {
    public var agentRuntime: AgentRuntimePlugin {
        let key = AgentRuntimePlugin.pluginKey
        guard let plugin = self.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.settings.plugins)")
        }
        return plugin
    }
}
