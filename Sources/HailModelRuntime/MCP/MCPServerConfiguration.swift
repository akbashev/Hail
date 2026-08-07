import HailCore

/// A host-provided MCP bridge exposed to local model harnesses.
///
/// Hail does not assume that the embedding application has a particular
/// executable name, subcommand, or environment vocabulary.
public struct MCPServerConfiguration: Sendable, Hashable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let agentIDEnvironmentKey: String?
    public let contextEnvironmentKey: String?

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        agentIDEnvironmentKey: String? = nil,
        contextEnvironmentKey: String? = nil
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.agentIDEnvironmentKey = agentIDEnvironmentKey
        self.contextEnvironmentKey = contextEnvironmentKey
    }

    public func environment(agentID: String?, context: String?) -> [String: String] {
        var environment: [String: String] = [:]
        if let agentIDEnvironmentKey, let agentID { environment[agentIDEnvironmentKey] = agentID }
        if let contextEnvironmentKey, let context { environment[contextEnvironmentKey] = context }
        return environment
    }
}
