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

public enum AgentDirectoryError: Error, Sendable, Equatable {
    case unavailable
}

public enum AgentRuntimeConfigurationError: Error, Sendable, Equatable {
    case invalidMaxToolRounds(Int)
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

    /// Derives the effect ``Authority`` for one agent from its durable spawn
    /// intent and activation-resolved workspace. The authority — a value of
    /// closures — is resolved here instead of riding on the `Codable` config.
    public typealias AuthorityProvider =
        @Sendable (_ spawnConfig: AgentSpawnConfig, _ workspace: AgentWorkspace) async -> any Authority

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
    private var store: AgentDirectoryStore?
    private let modelRouter: ModelRouter
    /// Host-selected model used only when no definition provider is supplied.
    public let defaultModel: AgentModelReference
    /// Host-selected effort used only when no definition provider is supplied.
    /// `nil` leaves the selected provider/model default unchanged.
    public let defaultReasoningEffort: ReasoningEffort?
    /// Host-selected ceiling on tool-call rounds within a single turn.
    /// There is intentionally no runtime fallback: this is an application
    /// safety policy supplied at composition time.
    public let maxToolRounds: Int

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

    public let workspaceProvider: WorkspaceProvider

    public var definitionProvider: DefinitionProvider?

    /// Pure transformation that assembles an agent's model request.
    public let assemblePrompt: PromptAssembler

    /// Product/host instructions rendered by the standard assembler. The
    /// runtime supplies structure and context; the host owns its task rules.
    public let promptInstructions: PromptAssemblyInstructions

    /// Optional compactor for non-session-owning endpoints (Ollama, hosted
    /// chat APIs): consulted before requests, its result is journaled as one
    /// `conversationCompacted` event. Session-owning harnesses manage their
    /// own context and are never offered compaction.
    public let contextCompactor: (any ContextCompactor)?

    /// Provider that resolves external context documents for an agent turn.
    /// When nil, the runtime falls back to inline context.
    public let contextProvider: AgentContextProvider?

    public init(
        defaultModel: AgentModelReference,
        maxToolRounds: Int,
        routerConfiguration: ModelRouterConfiguration,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        modelEndpointProvider: ModelEndpointProvider? = nil,
        extraToolsProvider: ExtraToolsProvider? = nil,
        authorityProvider: AuthorityProvider? = nil,
        workspaceProvider: @escaping WorkspaceProvider,
        definitionProvider: DefinitionProvider? = nil,
        contextProvider: AgentContextProvider? = nil,
        contextCompactor: (any ContextCompactor)? = nil,
        promptInstructions: PromptAssemblyInstructions = PromptAssemblyInstructions(),
        assemblePrompt: @escaping PromptAssembler = assembleStandardPrompt,
        defaultReasoningEffort: ReasoningEffort? = nil
    ) throws(AgentRuntimeConfigurationError) {
        guard maxToolRounds > 0 else {
            throw .invalidMaxToolRounds(maxToolRounds)
        }
        self.modelRouter = ModelRouter(
            configuration: routerConfiguration,
            mcpServerConfiguration: mcpServerConfiguration,
            modelEndpointProvider: modelEndpointProvider
        )
        self.defaultModel = defaultModel
        self.defaultReasoningEffort = defaultReasoningEffort
        self.maxToolRounds = maxToolRounds
        self.extraToolsProvider = extraToolsProvider
        self.authorityProvider = authorityProvider
        self.workspaceProvider = workspaceProvider
        self.definitionProvider = definitionProvider
        self.contextProvider = contextProvider
        self.contextCompactor = contextCompactor
        self.promptInstructions = promptInstructions
        self.assemblePrompt = assemblePrompt
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
            ?? .defaultDefinition(
                for: spawnConfig.agentID.role,
                model: defaultModel,
                reasoningEffort: defaultReasoningEffort
            )
    }

    // MARK: Model endpoints

    /// Returns the cached ``ModelEndpoint`` for the given configuration,
    /// creating and caching it if necessary.
    ///
    /// The caller owns the streaming effect; this method only resolves and
    /// caches the endpoint instance. `authority` is used only when a new
    /// endpoint is created — a cached endpoint keeps the authority it was
    /// built with. That is safe for per-turn lanes because the creation
    /// authority scopes only endpoint infrastructure (the harness spawn):
    /// the turn's lane authority is delivered per-stream through
    /// ``SessionOwningEndpoint/stream(messages:delta:authority:tools:responseType:)``
    /// and governs every model-facing effect, so the cache key deliberately
    /// has no authority component (see the invariant in `Agent.reasoningLoop`).
    public func endpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        try await modelRouter.endpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority,
            reasoningEffort: reasoningEffort
        )
    }

    /// Evicts the cached endpoint for the given configuration, tearing down
    /// its live harness session if it owns one. Agents call this when they
    /// accept deactivation so a passivated agent leaves no subprocess behind.
    public func evictEndpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        reasoningEffort: ReasoningEffort? = nil
    ) async {
        await modelRouter.evict(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            reasoningEffort: reasoningEffort
        )
    }

    /// Registers a custom endpoint for testing or programmatic override.
    public func register<E: ModelEndpoint>(
        _ endpoint: E,
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil
    ) async throws(ModelRouterError) {
        try await modelRouter.register(
            endpoint,
            for: model,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace
        )
    }

    // MARK: Agent directory

    public func register(entry: AgentDirectoryEntry) async throws {
        guard let store else { throw AgentDirectoryError.unavailable }
        try await store.register(entry: entry)
    }

    public func unregister(agentID: AgentID) async throws {
        guard let store else { throw AgentDirectoryError.unavailable }
        try await store.unregister(agentID: agentID)
    }

    public func entry(forAgentID agentID: AgentID) async throws -> AgentDirectoryEntry? {
        guard let store else { throw AgentDirectoryError.unavailable }
        return try await store.entry(forAgentID: agentID)
    }

    public func agents(ofType role: Role) async throws -> [AgentDirectoryEntry] {
        guard let store else { throw AgentDirectoryError.unavailable }
        return try await store.agents(ofType: role)
    }

    public func allAgents() async throws -> [AgentDirectoryEntry] {
        guard let store else { throw AgentDirectoryError.unavailable }
        return try await store.allAgents()
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
