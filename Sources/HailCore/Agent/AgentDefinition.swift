#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The default model identifier used for all Hail agents when no model is
/// configured.
///
/// This is intentionally a single source of truth so every fallback path in
/// the runtime points at the local Kimi Code provider.
public let defaultAgentModel: String = "kimi-code/kimi-for-coding"

/// Model providers resolved by ``ModelRouter``.
///
/// The UI presents these as the provider half of the model identifier; the
/// model name half is free-form and is passed through to the provider's API.
public let availableAgentModelProviders: [String] = [
    "kimi-code",
    "claude",
    "moonshot",
    "openai",
    "anthropic",
    "gemini",
    "ollama",
    "codex",
    "system",
]

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
    public let limits: Limits
    public let persona: AgentPersona?

    public init(
        role: Role,
        behavior: Behavior,
        limits: Limits,
        persona: AgentPersona? = nil
    ) {
        self.role = role
        self.behavior = behavior
        self.limits = limits
        self.persona = persona
    }

    public struct Behavior: Codable, Sendable {
        public let systemPrompt: String
        public let model: String
        public let execution: AgentExecutionPolicy

        public init(
            systemPrompt: String,
            model: String,
            execution: AgentExecutionPolicy = .autonomousWorkspace
        ) {
            self.systemPrompt = systemPrompt
            self.model = model
            self.execution = execution
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)

            self.model = try container.decode(String.self, forKey: .model)
            self.execution =
                try container.decodeIfPresent(AgentExecutionPolicy.self, forKey: .execution)
                ?? .autonomousWorkspace
        }

        enum CodingKeys: String, CodingKey {
            case systemPrompt = "system_prompt"
            case model
            case execution
        }
    }

    public struct Limits: Codable, Sendable {
        public let maxMemoryFragments: Int

        public init(
            maxMemoryFragments: Int = 10
        ) {
            self.maxMemoryFragments = maxMemoryFragments
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.maxMemoryFragments =
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .maxMemoryFragments
                ) ?? 10
        }

        enum CodingKeys: String, CodingKey {
            case maxMemoryFragments = "max_memory_fragments"
        }
    }

    enum CodingKeys: String, CodingKey {
        case role = "agent_type_id"
        case behavior
        case limits
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
    /// The generic fallback used when the host provides no definition.
    public static func defaultDefinition(for role: Role) -> AgentDefinition {
        return AgentDefinition(
            role: role,
            behavior: .init(
                systemPrompt: "You are the \(role) agent.",
                model: defaultAgentModel
            ),
            limits: .init()
        )
    }
}
