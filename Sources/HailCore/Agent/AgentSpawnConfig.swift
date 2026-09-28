/// A workspace resolved by the host for one activated agent.
///
/// This value is intentionally not `Codable`: filesystem paths are
/// environment-specific and must not be persisted with distributed spawn
/// configuration. Hosts resolve it from the logical scope at activation.
public struct AgentWorkspace: Sendable, Hashable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }
}

/// The host's configuration for one agent identity, produced by the runtime's
/// spawn-config provider at every activation. Callers never supply it: an
/// agent is addressed by `AgentID` alone.
public struct AgentSpawnConfig: Codable, Sendable {
    public let agentID: AgentID
    /// The durable resource namespace this agent's workspace-scoped effects
    /// (currently file access) address. Defaults to a namespace private to
    /// this agent's own id, so omitting it fails closed toward isolation
    /// rather than toward sharing.
    public let workspaceID: WorkspaceID
    public let agentDirectoryID: AgentDirectoryID
    public let resumesInterruptedTurns: Bool
    public let snapshotPolicy: AgentSnapshotPolicy

    public init(
        agentID: AgentID,
        workspaceID: WorkspaceID? = nil,
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        resumesInterruptedTurns: Bool = true,
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) {
        self.agentID = agentID
        self.workspaceID = workspaceID ?? WorkspaceID(agentID.rawValue)
        self.agentDirectoryID = agentDirectoryID
        self.resumesInterruptedTurns = resumesInterruptedTurns
        self.snapshotPolicy = snapshotPolicy
    }
}
