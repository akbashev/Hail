import AnyLanguageModel

/// Typed result returned by a chat agent at the end of a chat turn.
///
/// Even though it currently wraps a single string, using a domain type makes the
/// chat boundary explicit and gives the product a place to add metadata later
/// (e.g. citations, follow-up suggestions).
///
/// Lives in `Hail` (peer of the other `AgentOutput` vocabulary), not
/// in a feature module: its session log and participant history, the
/// MCP report shim, and the chat projection all consume it, and none of them
/// may depend on a feature.
public struct ChatResponse: Codable, Sendable, Hashable, AgentOutput {
    public let content: String

    public init(content: String) {
        self.content = content
    }

    public init(_ content: GeneratedContent) throws {
        guard case .string(let value) = content.kind else {
            throw GeneratedContentConversionError.typeMismatch
        }
        self.content = value
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(kind: .string(content))
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: ChatResponse.self,
            description: "Chat response content",
            properties: [
                .init(name: "content", description: "Response text", type: String.self)
            ]
        )
    }

    public static let reportToolName = "report_chat_response"

    public static var outputContract: AgentOutputContract {
        .plainText
    }

    public static var reportToolSchema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: reportToolName,
                description: "Report the final content of a chat turn.",
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "content": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The chat response text.",
                            enumValues: nil
                        )
                    ],
                    required: ["content"]
                )
            )
        )
    }
}
