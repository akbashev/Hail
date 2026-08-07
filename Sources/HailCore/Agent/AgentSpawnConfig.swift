public enum AgentScope: Codable, Sendable {
    case sharedRoot
    case isolatedWorkspace(path: String)

    public var path: String? {
        switch self {
        case .sharedRoot: nil
        case .isolatedWorkspace(let path): path
        }
    }
}

public struct AgentSpawnConfig: Codable, Sendable {
    public let agentID: AgentID
    public let projectRootPath: String
    public let scope: AgentScope
    public let agentDirectoryID: AgentDirectoryID
    public let resumesInterruptedTurns: Bool

    public init(
        agentID: AgentID,
        projectRootPath: String,
        scope: AgentScope = .sharedRoot,
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        resumesInterruptedTurns: Bool = true
    ) {
        self.agentID = agentID
        self.projectRootPath = projectRootPath
        self.scope = scope
        self.agentDirectoryID = agentDirectoryID
        self.resumesInterruptedTurns = resumesInterruptedTurns
    }
}
