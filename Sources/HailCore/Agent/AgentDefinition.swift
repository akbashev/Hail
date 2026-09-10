#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Provider identifier used by a model.
///
/// This is a value type rather than an enum so hosts can introduce a provider
/// without changing Hail's source or waiting for a new release. The static
/// values are the providers understood by the built-in router.
public struct AgentModelProvider: RawRepresentable, Codable, Sendable, Hashable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    public static let kimiCode = Self(rawValue: "kimi-code")
    public static let claude = Self(rawValue: "claude")
    public static let moonshot = Self(rawValue: "moonshot")
    public static let openAI = Self(rawValue: "openai")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let gemini = Self(rawValue: "gemini")
    public static let ollama = Self(rawValue: "ollama")
    public static let codex = Self(rawValue: "codex")
    public static let system = Self(rawValue: "system")

    public static let builtIns: [Self] = [
        .kimiCode, .claude, .moonshot, .openAI, .anthropic,
        .gemini, .ollama, .codex, .system,
    ]

    public static func custom(_ rawValue: String) -> Self {
        Self(rawValue: rawValue)
    }
}

public enum AgentModelError: Error, Sendable, Equatable {
    case empty
    case missingProvider(String)
    case missingID(String)
}

/// A fully specified provider/model pair.
///
/// The serialized form is the familiar `provider/model` string, while the
/// domain value keeps both parts typed at every call site.
public struct AgentModel: Codable, Sendable, Hashable, CustomStringConvertible {
    public let provider: AgentModelProvider
    public let id: AgentModelID

    public init(
        provider: AgentModelProvider,
        id: AgentModelID
    ) throws(AgentModelError) {
        guard !provider.rawValue.isEmpty else {
            throw .missingProvider(provider.rawValue)
        }
        let rawID = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else {
            throw .missingID(provider.rawValue)
        }
        self.provider = provider
        self.id = AgentModelID(rawValue: rawID)
    }

    public init(_ identifier: String) throws(AgentModelError) {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw .empty }
        let parts = identifier.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            throw .missingID(identifier)
        }
        try self.init(
            provider: AgentModelProvider(rawValue: String(parts[0])),
            id: AgentModelID(rawValue: String(parts[1]))
        )
    }

    public var rawValue: String { identifier }
    public var identifier: String { "\(provider.rawValue)/\(id.rawValue)" }
    public var description: String { identifier }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

public let availableAgentModelProviders: [String] =
    AgentModelProvider.builtIns.map(\.rawValue)

/// Provider-neutral execution policy for local model runtimes.
///
/// Agents may run inside isolated workspaces, so the default policy allows
/// autonomous edits there while keeping
/// the model runtime sandboxed to the workspace boundary.
public struct AgentExecutionPolicy: Codable, Sendable, Hashable {
    public enum Sandbox: String, Codable, Sendable, Hashable {
        case readOnly = "read-only"
        case workspaceWrite = "workspace-write"
        case unrestricted = "danger-full-access"
    }

    public enum ApprovalPolicy: String, Codable, Sendable, Hashable {
        case untrusted
        case onRequest = "on-request"
        case never
    }

    public let sandbox: Sandbox
    public let approvalPolicy: ApprovalPolicy

    public init(
        sandbox: Sandbox = .workspaceWrite,
        approvalPolicy: ApprovalPolicy = .never
    ) {
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
    }

    public static let autonomousWorkspace = AgentExecutionPolicy()

    private enum CodingKeys: String, CodingKey {
        case sandbox
        case approvalPolicy = "approval_policy"
    }
}

/// A durable identity layered over an agent role's operational behavior.
///
/// The host may expose this as editable configuration. Hail treats it as part
/// of the definition loaded when the actor activates, never as transient turn
/// context.
public struct AgentPersona: Codable, Sendable, Hashable {
    public let displayName: String?
    public let instructions: String

    public init(displayName: String? = nil, instructions: String) {
        self.displayName = displayName
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case instructions
    }
}

public struct AgentDefinition: Codable, Sendable {
    public let role: Role
    public let behavior: Behavior
    public let persona: AgentPersona?

    public init(
        role: Role,
        behavior: Behavior,
        persona: AgentPersona? = nil
    ) {
        self.role = role
        self.behavior = behavior
        self.persona = persona
    }

    public struct Behavior: Codable, Sendable {
        public let systemPrompt: String
        public let model: AgentModel
        /// Optional host-selected reasoning effort. When absent, the model
        /// provider chooses its own default for the selected model.
        public let reasoningEffort: ReasoningEffort?
        public let execution: AgentExecutionPolicy

        public init(
            systemPrompt: String,
            model: AgentModel,
            execution: AgentExecutionPolicy = .autonomousWorkspace,
            reasoningEffort: ReasoningEffort? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.execution = execution
        }

        public init(
            systemPrompt: String,
            model: String,
            execution: AgentExecutionPolicy = .autonomousWorkspace,
            reasoningEffort: ReasoningEffort? = nil
        ) throws(AgentModelError) {
            self.init(
                systemPrompt: systemPrompt,
                model: try AgentModel(model),
                execution: execution,
                reasoningEffort: reasoningEffort
            )
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)

            self.model = try container.decode(AgentModel.self, forKey: .model)
            self.reasoningEffort = try container.decodeIfPresent(
                ReasoningEffort.self,
                forKey: .reasoningEffort
            )
            self.execution =
                try container.decodeIfPresent(AgentExecutionPolicy.self, forKey: .execution)
                ?? .autonomousWorkspace
        }

        enum CodingKeys: String, CodingKey {
            case systemPrompt = "system_prompt"
            case model
            case reasoningEffort = "reasoning_effort"
            case execution
        }
    }

    enum CodingKeys: String, CodingKey {
        case role = "agent_type_id"
        case behavior
        case persona
    }
}

public struct AgentSummary: Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension AgentDefinition {
    /// Constructs the generic shape used when the host provides no definition.
    /// The host must supply the model; Hail does not choose a provider or
    /// model on its behalf.
    public static func defaultDefinition(
        for role: Role,
        model: AgentModel,
        reasoningEffort: ReasoningEffort? = nil
    ) -> AgentDefinition {
        return AgentDefinition(
            role: role,
            behavior: .init(
                systemPrompt: "You are the \(role) agent.",
                model: model,
                reasoningEffort: reasoningEffort
            )
        )
    }
}
