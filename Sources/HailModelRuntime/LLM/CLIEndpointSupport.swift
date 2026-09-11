import AnyLanguageModel
import HailCore
import Logging

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Shared prompt envelopes and final-output decoding for local harnesses.
///
/// These endpoints cannot use native function calling, so the model is asked
/// to return exactly one JSON object:
/// `{"kind":"tool_calls"|"output","tool_calls":[...],"output":{...}|null,"content":"..."|null}`.
/// Hail parses that envelope and executes the tool calls itself.
enum CLIEndpointSupport {
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
    static func structuredOutputSchema<T: Codable & Generable & Sendable>(for type: T.Type) throws -> Data {
        let outputSchema = try jsonSchema(from: T.generationSchema)

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
    static func finalOutputSchema<T: Codable & Generable & Sendable>(for type: T.Type) throws -> Data {
        let schema = try jsonSchema(from: T.generationSchema)
        return try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonSchema(from schema: GenerationSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let result = value as? [String: Any] else {
            throw ModelEndpointError.invalidRequest("Generated output schema is not a JSON object")
        }
        return result
    }
}
