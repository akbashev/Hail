/// Identifies a human actor in the system (e.g. a person using the web UI or
/// the CLI). This is a thin raw-value wrapper used only at external boundaries;
/// domain events and commands carry the typed `Performer` instead.
public struct UserID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The originator of a host event or command.
///
/// Domain performers are either a user, an agent, or the supervisor. Replacing
/// the previous `String`ly typed `performedBy` keeps the three kinds distinct
/// and keeps supervisor-origin checks typed.
public enum Performer: Codable, Sendable, Hashable {
    case user(UserID)
    case agent(AgentID)
    case supervisor(AgentID)

    /// The underlying `AgentID` when the performer is an agent or the
    /// supervisor; `nil` for a user.
    public var agentID: AgentID? {
        switch self {
        case .user:
            return nil
        case .agent(let agentID), .supervisor(let agentID):
            return agentID
        }
    }

    /// `true` when the performer is the supervisor.
    public var isSupervisor: Bool {
        if case .supervisor = self { return true }
        return false
    }

    /// A human-readable name for read models and UI strings. This is the only
    /// sanctioned conversion from the typed performer back into a string, and it
    /// is intended for display boundaries, not domain logic.
    public var displayName: String {
        switch self {
        case .user(let userID):
            return userID.rawValue
        case .agent(let agentID), .supervisor(let agentID):
            return agentID.rawValue
        }
    }

    /// A compact name for dense UI surfaces such as comment bylines: agents are
    /// shown by role only (`@reviewer`), without the context suffix
    /// (`@reviewer-B15171DF-…`).
    public var compactDisplayName: String {
        switch self {
        case .user(let userID):
            return userID.rawValue
        case .agent(let agentID), .supervisor(let agentID):
            return agentID.role.rawValue
        }
    }

}

extension Performer: CustomStringConvertible {
    public var description: String { displayName }
}
