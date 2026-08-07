/// A role or agent type defined by the project configuration (e.g. `coder`,
/// `reviewer`, `supervisor`). This is *not* a concrete running actor; it is the
/// template used to spawn one.
public struct Role: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Identifies the context in which an agent instance runs. Hosts define their
/// own context identifiers; `chat` and `main` are common runtime conventions.
public struct AgentContextID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// The special context used for interactive chat agents.
    public static let chat = AgentContextID("chat")

    /// The context of a role's single primary instance (e.g. the supervisor's
    /// brain): one agent per role.
    public static let main = AgentContextID("main")

    /// Whether this context is the interactive chat context.
    public var isChat: Bool {
        self == .chat
    }
}

/// Identifies a concrete running agent instance.
///
/// An agent ID is composed of a `Role` and an `AgentContextID`. The raw value
/// formats as `"<role>-<context>"` and is used as the virtual actor ID.
///
/// Examples:
///   - `AgentID(role: "supervisor", contextID: "main")` → `supervisor-main`
///   - `AgentID(role: "coder", contextID: "T-42")` → `coder-T-42`
public struct AgentID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let role: Role
    public let contextID: AgentContextID

    public init(role: Role, contextID: AgentContextID) {
        self.role = role
        self.contextID = contextID
    }

    public var rawValue: String {
        "\(role.rawValue)-\(contextID.rawValue)"
    }

    public var description: String { rawValue }
}

extension AgentID: RawRepresentable {
    public init?(rawValue: String) {
        // A raw agent ID must contain both a role and a context, separated by
        // the first hyphen. Roles must not contain hyphens.
        guard let hyphenIndex = rawValue.firstIndex(of: "-") else {
            return nil
        }
        let rolePart = String(rawValue[..<hyphenIndex])
        let contextPart = String(rawValue[rawValue.index(after: hyphenIndex)...])
        self.role = Role(rolePart)
        self.contextID = AgentContextID(contextPart)
    }
}
