#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Provider identifier used by a model route.
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

public enum AgentModelRouteError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case missingModel(String)
}

/// A model selection as stored in an agent definition. Construction validates
/// the serialized `provider/model` identifier, so an invalid reference cannot
/// enter the domain model.
public struct AgentModelReference: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws(AgentModelReferenceError) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw .empty }
        do {
            _ = try AgentModelRoute(identifier: normalized)
        } catch {
            throw .invalidRoute(error)
        }
        self.rawValue = normalized
    }

    public var description: String { rawValue }

    public func route() throws(AgentModelRouteError) -> AgentModelRoute {
        try AgentModelRoute(identifier: rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AgentModelReferenceError: Error, Sendable, Equatable {
    case empty
    case invalidRoute(AgentModelRouteError)
}

/// A fully specified provider/model pair. Model names remain free-form so new
/// provider releases do not require a Hail update, but absence is invalid.
public struct AgentModelRoute: Sendable, Hashable {
    public let provider: AgentModelProvider
    public let model: String

    public init(
        provider: AgentModelProvider,
        model: String
    ) throws(AgentModelRouteError) {
        guard !provider.rawValue.isEmpty else {
            throw .unknownProvider(provider.rawValue)
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw .missingModel(provider.rawValue)
        }
        self.provider = provider
        self.model = model
    }

    public init(identifier: String) throws(AgentModelRouteError) {
        let parts = identifier.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            throw .missingModel(identifier)
        }
        let providerName = String(parts[0])
        let provider = AgentModelProvider(rawValue: providerName)
        try self.init(provider: provider, model: String(parts[1]))
    }

    public var identifier: String { "\(provider.rawValue)/\(model)" }
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
        public let model: AgentModelReference
        public let execution: AgentExecutionPolicy

        public init(
            systemPrompt: String,
            model: AgentModelReference,
            execution: AgentExecutionPolicy = .autonomousWorkspace
        ) {
            self.systemPrompt = systemPrompt
            self.model = model
            self.execution = execution
        }

        public init(
            systemPrompt: String,
            model: String,
            execution: AgentExecutionPolicy = .autonomousWorkspace
        ) throws(AgentModelReferenceError) {
            self.init(
                systemPrompt: systemPrompt,
                model: try AgentModelReference(model),
                execution: execution
            )
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)

            self.model = try container.decode(AgentModelReference.self, forKey: .model)
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
    /// Constructs the generic shape used when the host provides no definition.
    /// The host must supply the model; Hail does not choose a provider or
    /// model on its behalf.
    public static func defaultDefinition(
        for role: Role,
        model: AgentModelReference
    ) -> AgentDefinition {
        return AgentDefinition(
            role: role,
            behavior: .init(
                systemPrompt: "You are the \(role) agent.",
                model: model
            ),
            limits: .init()
        )
    }
}
