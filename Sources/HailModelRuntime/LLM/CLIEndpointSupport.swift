import AnyLanguageModel
import HailCore
import Logging

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How a CLI-backed endpoint expects the model to finish a turn.
enum CLIResponseMode {
    case chat
    case structured
}

struct CLIParsedResponse {
    let content: String?
    let toolCalls: [LLMToolCall]?
    let output: String?
}

/// Shared prompt envelopes and final-output decoding for local harnesses.
///
/// These endpoints cannot use native function calling, so the model is asked
/// to return exactly one JSON object:
/// `{"kind":"tool_calls"|"output","tool_calls":[...],"output":{...}|null,"content":"..."|null}`.
/// Hail parses that envelope and executes the tool calls itself.
enum CLIEndpointSupport {
    static func makePrompt(
        harness: String,
        messages: [LLMMessage],
        tools: [ToolDefinition]?,
        responseMode: CLIResponseMode
    ) -> String {
        let finalResponseInstructions: String =
            switch responseMode {
            case .chat:
                """
                To answer without tools:
                {"kind":"output","tool_calls":[],"output":null,"content":"your final answer"}

                After tool results are provided in the transcript, return a final {"kind":"output","tool_calls":[],"output":null,"content":"..."} response.
                """
            case .structured:
                """
                When finished:
                {"kind":"output","tool_calls":[],"output":{...},"content":null}

                The final `output` object must match the structured output schema. Do not represent the final output as a tool call.
                """
            }

        var parts: [String] = [
            """
            You are running as a Hail agent through \(harness).
            Do not call MCP tools or external Hail processes.
            Hail itself will execute tool calls after you return them.

            Return exactly one JSON object and no Markdown.

            To request tools:
            {"kind":"tool_calls","tool_calls":[{"id":"call_1","name":"tool_name","arguments":{"key":"value"}}],"output":null,"content":null}

            Tool-call arguments must be a JSON object matching the tool schema. Preserve arrays, objects, numbers, booleans, and nulls as JSON values.
            If you need multiple actions, return multiple tool calls in order.

            \(finalResponseInstructions)
            """
        ]

        if let tools, !tools.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(tools),
                let json = String(data: data, encoding: .utf8)
            {
                parts.append("Available Hail tool schemas:\n\(json)")
            } else {
                let toolNames = tools.map(\.name).sorted().joined(separator: ", ")
                parts.append("Available Hail tools: \(toolNames)")
            }
        }

        for message in messages {
            let role: String =
                switch message.role {
                case .system: "System"
                case .user: "User"
                case .assistant: "Assistant"
                case .tool: "Tool"
                }

            var content = message.content
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let calls =
                    toolCalls
                    .map { "\($0.function.name): \($0.function.arguments)" }
                    .joined(separator: "\n")
                content += "\nTool calls:\n\(calls)"
            }
            if let toolCallID = message.toolCallID {
                content += "\nTool call ID: \(toolCallID)"
            }
            parts.append("\(role):\n\(content)")
        }

        return parts.joined(separator: "\n\n")
    }

    static func parseResponse(_ rawContent: String) -> CLIParsedResponse {
        let content = stripCodeFence(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = content.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(CLIStructuredResponse.self, from: data)
        else {
            return CLIParsedResponse(content: content.isEmpty ? nil : content, toolCalls: nil, output: nil)
        }

        let calls = decoded.toolCalls?.map { call in
            LLMToolCall(
                id: call.id,
                type: "function",
                function: .init(
                    name: call.name,
                    arguments: call.arguments
                )
            )
        }
        let output = rawOutputJSON(from: data)
        return CLIParsedResponse(content: decoded.content, toolCalls: calls, output: output)
    }

    static func stripCodeFence(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty, lines[0].hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private static func rawOutputJSON(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any],
            let output = envelope["output"],
            !(output is NSNull)
        else {
            return nil
        }

        if JSONSerialization.isValidJSONObject(output),
            let data = try? JSONSerialization.data(withJSONObject: output),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        if let output = output as? String {
            return encodeJSON(output)
        }
        if let output = output as? Bool {
            return encodeJSON(output)
        }
        if let output = output as? NSNumber {
            return output.stringValue
        }
        return nil
    }

    static func decodeOutcome<T: Codable & Generable & Sendable>(
        fromJSON json: String,
        as type: T.Type,
        logger: Logger
    ) -> T? {
        let stripped = stripCodeFence(json)
        if let data = stripped.data(using: .utf8),
            let direct = try? JSONDecoder().decode(T.self, from: data)
        {
            return direct
        }

        do {
            let content = try GeneratedContent(json: stripped)
            return try T(content)
        } catch {
            logger.debug(
                "Failed to decode structured CLI output",
                metadata: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    static func decodeOutcome<T: Codable & Generable & Sendable>(
        fromText text: String,
        as type: T.Type,
        logger: Logger
    ) -> T? {
        do {
            return try T(GeneratedContent(kind: .string(text)))
        } catch {
            logger.debug(
                "Failed to decode CLI text output",
                metadata: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    /// JSON Schema for the response envelope, with the structured `output`
    /// constrained to the agent's report schema.
    static func structuredOutputSchema<T: AgentOutput>(for type: T.Type) throws -> Data {
        let outputSchema: [String: Any]
        switch T.outputContract {
        case .plainText:
            outputSchema = ["type": "string"]
        case .reportTool(_, let schema):
            outputSchema = jsonSchema(from: schema.parameters)
        }

        let toolCallSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "id": ["type": "string"],
                "name": ["type": "string"],
                "arguments": ["type": "object"],
            ],
            "required": ["id", "name", "arguments"],
        ]

        let envelope: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["tool_calls", "output"],
                ],
                "tool_calls": [
                    "type": "array",
                    "items": toolCallSchema,
                ],
                "output": [
                    "anyOf": [
                        outputSchema,
                        ["type": "null"],
                    ]
                ],
                "content": [
                    "anyOf": [
                        ["type": "string"],
                        ["type": "null"],
                    ]
                ],
            ],
            "required": ["kind", "tool_calls", "output", "content"],
        ]

        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    /// JSON Schema for a provider that constrains its final message directly,
    /// rather than wrapping it in Hail's legacy CLI tool-call envelope.
    static func finalOutputSchema<T: AgentOutput>(for type: T.Type) throws -> Data {
        let schema: [String: Any]
        switch T.outputContract {
        case .plainText:
            schema = ["type": "string"]
        case .reportTool(_, let reportSchema):
            schema = jsonSchema(from: reportSchema.parameters)
        }
        return try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonSchema(from schema: GenerationSchema) -> [String: Any] {
        guard
            let data = try? JSONEncoder().encode(schema),
            let value = try? JSONSerialization.jsonObject(with: data),
            let result = value as? [String: Any]
        else {
            return [:]
        }
        return result
    }
}

private struct CLIStructuredResponse: Decodable {
    let kind: String?
    let content: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case kind
        case content
        case toolCalls = "tool_calls"
    }

    struct ToolCall: Decodable {
        let id: String
        let name: String
        let arguments: String

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case arguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decode(String.self, forKey: .name)
            if let arguments = try? container.decode(String.self, forKey: .arguments) {
                self.arguments = arguments
            } else {
                let arguments = try container.decode(JSONValue.self, forKey: .arguments)
                self.arguments = CLIEndpointSupport.encodeJSON(arguments) ?? "{}"
            }
        }
    }
}

private enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}
