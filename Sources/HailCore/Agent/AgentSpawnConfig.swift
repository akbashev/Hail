public enum AgentScope: Codable, Sendable {
    case sharedRoot
    case isolatedWorkspace
}

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

public struct AgentSpawnConfig: Codable, Sendable {
    public let agentID: AgentID
    public let scope: AgentScope
    public let agentDirectoryID: AgentDirectoryID
    public let resumesInterruptedTurns: Bool

    public init(
        agentID: AgentID,
        scope: AgentScope = .sharedRoot,
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        resumesInterruptedTurns: Bool = true
    ) {
        self.agentID = agentID
        self.scope = scope
        self.agentDirectoryID = agentDirectoryID
        self.resumesInterruptedTurns = resumesInterruptedTurns
    }
}
