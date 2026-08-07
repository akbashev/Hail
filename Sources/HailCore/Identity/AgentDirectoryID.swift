/// Strongly-typed identifier for the agent directory actor.
public struct AgentDirectoryID: Codable, Sendable, Hashable, RawRepresentable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
