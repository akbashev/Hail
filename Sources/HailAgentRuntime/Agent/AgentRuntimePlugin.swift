import DistributedCluster
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

// MARK: - Singleton store

/// A cluster singleton that holds the in-memory agent directory. No event
/// sourcing — the directory is rebuilt on activation by agents re-registering.
public distributed actor AgentDirectoryStore: ClusterSingleton {
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

/// The single cluster plugin that hosts the agent directory, resolves model
/// endpoints, and delegates tool injection and prompt strategy to configurable
/// closures.
///
/// A host configures these closures at bootstrap, keeping product-specific
/// persistence, tools, and policy outside Hail.
public actor AgentRuntimePlugin: ActorLifecyclePlugin {
    public typealias ExtraToolsProvider =
        @Sendable (
            _ agentID: AgentID,
            _ sourceAgentID: AgentID,
            _ actorSystem: ClusterSystem
        ) async throws -> [any Tool]

    /// Derives the effect ``Authority`` for one agent from its spawn config.
    /// The config is `Codable` (journaled), so authority — a value of
    /// closures — is resolved here at activation instead of riding on it.
    public typealias AuthorityProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig) async -> any Authority

    /// Loads a definition from the host's chosen configuration store. Returning
    /// `nil` selects Hail's generic role default.
    public typealias DefinitionProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig) async throws -> AgentDefinition?

    public static let pluginKey: Key = "$agentRuntime"

    public nonisolated var key: Key {
        Self.pluginKey
    }

    private var actorSystem: ClusterSystem!
    private var store: AgentDirectoryStore?
    private let modelRouter: ModelRouter

    /// Optional closure that returns extra tools an agent should register.
    /// Invoked **once per turn** (the registry is rebuilt fresh each turn —
    /// see `docs/plans/per-turn-tool-registry.md`), so implementations must
    /// be cheap and side-effect-free: journal replays and value construction
    /// are fine, network calls are not.
    public var extraToolsProvider: ExtraToolsProvider?

    /// Optional closure that derives an agent's effect authority. When nil,
    /// file effects are pinned to the agent's workspace and everything else
    /// is open (``CompositeAuthority/workspaceDefault(root:)``).
    public var authorityProvider: AuthorityProvider?

    public var definitionProvider: DefinitionProvider?

    /// Policy used to assemble an agent's LLM context before each turn.
    public let promptPolicy: PromptPolicy = .default

    /// Provider that resolves external context documents for an agent turn.
    /// When nil, the runtime falls back to inline context.
    public let contextProvider: AgentContextProvider?

    public init(
        projectRootPath: String? = nil,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        modelEndpointProvider: ModelEndpointProvider? = nil,
        extraToolsProvider: ExtraToolsProvider? = nil,
        authorityProvider: AuthorityProvider? = nil,
        definitionProvider: DefinitionProvider? = nil,
        contextProvider: AgentContextProvider? = nil
    ) {
        self.modelRouter = ModelRouter(
            projectRootPath: projectRootPath,
            mcpServerConfiguration: mcpServerConfiguration,
            modelEndpointProvider: modelEndpointProvider
        )
        self.extraToolsProvider = extraToolsProvider
        self.authorityProvider = authorityProvider
        self.definitionProvider = definitionProvider
        self.contextProvider = contextProvider
    }

    /// Resolves the effect authority for one agent. Defaults to
    /// ``CompositeAuthority/workspaceDefault(root:)`` — file effects pinned
    /// to the agent's workspace, everything else open: the behavior every
    /// agent had before authorities existed.
    public func authority(for spawnConfig: AgentSpawnConfig) async -> any Authority {
        await authorityProvider?(spawnConfig)
            ?? CompositeAuthority.workspaceDefault(
                root: spawnConfig.scope.path ?? spawnConfig.projectRootPath
            )
    }

    public func definition(for spawnConfig: AgentSpawnConfig) async throws -> AgentDefinition {
        try await definitionProvider?(spawnConfig)
            ?? .defaultDefinition(for: spawnConfig.agentID.role)
    }

    // MARK: Model endpoints

    /// Returns the cached ``ModelEndpoint`` for the given configuration,
    /// creating and caching it if necessary.
    ///
    /// The caller owns the streaming effect; this method only resolves and
    /// caches the endpoint instance. `authority` is used only when a new
    /// endpoint is created — a cached endpoint keeps the authority it was
    /// built with.
    public func endpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        try await modelRouter.endpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority
        )
    }

    /// Evicts the cached endpoint for the given configuration, tearing down
    /// its live harness session if it owns one. Agents call this when they
    /// accept deactivation so a passivated agent leaves no subprocess behind.
    public func evictEndpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace
    ) async {
        await modelRouter.evict(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy
        )
    }

    /// Registers a custom endpoint for testing or programmatic override.
    public func register<E: ModelEndpoint>(
        _ endpoint: E,
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil
    ) async throws(ModelRouterError) {
        try await modelRouter.register(
            endpoint,
            for: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: workingDirectory
        )
    }

    // MARK: Agent directory

    public func register(entry: AgentDirectoryEntry) async throws {
        // The directory is an in-memory singleton rebuilt on activation; if the
        // plugin has stopped (node shutdown) a fire-and-forget caller may still
        // tick. Degrade to a no-op instead of crashing the process.
        guard let store else { return }
        try await store.register(entry: entry)
    }

    public func unregister(agentID: AgentID) async {
        guard let store else { return }
        try? await store.unregister(agentID: agentID)
    }

    public func entry(forAgentID agentID: AgentID) async -> AgentDirectoryEntry? {
        guard let store else { return nil }
        return try? await store.entry(forAgentID: agentID)
    }

    public func agents(ofType role: Role) async -> [AgentDirectoryEntry] {
        guard let store else { return [] }
        return (try? await store.agents(ofType: role)) ?? []
    }

    public func allAgents() async -> [AgentDirectoryEntry] {
        guard let store else { return [] }
        return (try? await store.allAgents()) ?? []
    }

    // MARK: Tool injection

    /// Returns additional tools the runtime wants to make available to this agent.
    /// Hail registers only its intrinsic clock and agent-messaging tools. The
    /// host supplies environmental and product-specific tools here.
    public func extraTools(
        forAgentID agentID: AgentID,
        sourceAgentID: AgentID,
        actorSystem: ClusterSystem
    ) async throws -> [any Tool] {
        try await extraToolsProvider?(agentID, sourceAgentID, actorSystem) ?? []
    }

    // MARK: Lifecycle hooks

    public func start(_ system: ClusterSystem) async throws {
        self.actorSystem = system
        self.store = try await system.singleton.host(name: "\(Self.pluginKey)_store") {
            AgentDirectoryStore(actorSystem: $0)
        }
    }

    public func stop(_ system: ClusterSystem) async {
        self.store = nil
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
