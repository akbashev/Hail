public struct LLMMessage: Codable, Sendable {
    public let role: Role
    public let content: String
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
        name: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

}

public struct LLMToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let function: FunctionCall

    public init(id: String, type: String, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }

    public struct FunctionCall: Codable, Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
}

public struct LLMResponse: Codable, Sendable {
    public let content: String?
    public let toolCalls: [LLMToolCall]?
    public let usage: Usage?

    public init(content: String?, toolCalls: [LLMToolCall]?, usage: Usage?) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
    }

    public struct Usage: Codable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int

        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }
}

public struct LLMToolSchema: Codable, Sendable {
    public let type: String
    public let function: FunctionSchema

    public init(type: String, function: FunctionSchema) {
        self.type = type
        self.function = function
    }

    public struct FunctionSchema: Codable, Sendable {
        public let name: String
        public let description: String
        public let parameters: ParameterSchema

        public init(name: String, description: String, parameters: ParameterSchema) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public struct ParameterSchema: Codable, Sendable {
        public let type: String
        public let properties: [String: PropertySchema]?
        public let required: [String]?

        public init(type: String, properties: [String: PropertySchema]?, required: [String]?) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }

    public final class PropertySchema: Codable, Sendable {
        public let type: String
        public let description: String
        public let enumValues: [String]?
        public let items: PropertySchema?
        public let properties: [String: PropertySchema]?
        public let required: [String]?

        public init(
            type: String,
            description: String,
            enumValues: [String]?,
            items: PropertySchema? = nil,
            properties: [String: PropertySchema]? = nil,
            required: [String]? = nil
        ) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
            self.items = items
            self.properties = properties
            self.required = required
        }

        enum CodingKeys: String, CodingKey {
            case type
            case description
            case enumValues = "enum"
            case items
            case properties
            case required
        }
    }
}
