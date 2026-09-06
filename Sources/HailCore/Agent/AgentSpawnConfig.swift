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
    public let snapshotPolicy: AgentSnapshotPolicy

    private enum CodingKeys: String, CodingKey {
        case agentID
        case scope
        case agentDirectoryID
        case resumesInterruptedTurns
        case snapshotPolicy
    }

    public init(
        agentID: AgentID,
        scope: AgentScope = .sharedRoot,
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        resumesInterruptedTurns: Bool = true,
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) {
        self.agentID = agentID
        self.scope = scope
        self.agentDirectoryID = agentDirectoryID
        self.resumesInterruptedTurns = resumesInterruptedTurns
        self.snapshotPolicy = snapshotPolicy
    }

    /// Decoding remains compatible with spawn configurations written before
    /// snapshot policy became part of the dependency.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.agentID = try container.decode(AgentID.self, forKey: .agentID)
        self.scope = try container.decode(AgentScope.self, forKey: .scope)
        self.agentDirectoryID = try container.decode(
            AgentDirectoryID.self,
            forKey: .agentDirectoryID
        )
        self.resumesInterruptedTurns = try container.decode(
            Bool.self,
            forKey: .resumesInterruptedTurns
        )
        self.snapshotPolicy = try container.decodeIfPresent(
            AgentSnapshotPolicy.self,
            forKey: .snapshotPolicy
        ) ?? .default
    }
}
