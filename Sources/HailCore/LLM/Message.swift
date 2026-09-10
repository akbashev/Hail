import AnyLanguageModel

public struct LLMMessage: Codable, Sendable, Equatable {
    public let role: Role
    public let content: String
    /// Provider reasoning that belongs to this assistant message.
    ///
    /// Some providers require the reasoning to be sent back together with
    /// assistant tool calls on the next request. It is deliberately separate
    /// from `content`: reasoning is protocol state, not user-facing text.
    public let thinking: String?
    public let name: String?
    public let toolCalls: [LLMToolCall]?
    public let toolCallID: String?

    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public init(
        role: Role,
        content: String,
        thinking: String? = nil,
        name: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

}

public struct LLMToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let function: FunctionCall

    public init(id: String, type: String, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }

    public struct FunctionCall: Codable, Sendable, Equatable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
}

/// Provider-neutral information needed to expose a Hail tool to a model.
///
/// The argument schema is AnyLanguageModel's `GenerationSchema`, so schema
/// generation, unions, and provider serialization have one source of truth.
/// Effect authorization and execution remain owned by Hail's `Tool` protocol.
public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema

    public init(name: String, description: String, parameters: GenerationSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
