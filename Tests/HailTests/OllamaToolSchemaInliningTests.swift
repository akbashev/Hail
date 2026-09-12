import AnyLanguageModel
import Foundation
import Testing

@testable import HailModelRuntime

/// Ollama's grammar builder follows a `$ref` only at the document root; an
/// inner reference silently disables the constraint. The tool-parameter
/// path inlines every local reference so declared argument types are
/// enforced at sampling time.
@Suite("Ollama tool schema inlining")
struct OllamaToolSchemaInliningTests {
    @Generable
    struct DailyInput: Codable, Sendable {
        let place: String
        let region: String?
        let days: Int
    }

    private func object(_ value: AnyCodableValue?, _ label: String) throws -> [String: AnyCodableValue] {
        guard case .object(let object)? = value else {
            Issue.record("Expected an object at \(label)")
            throw NotAnObject()
        }
        return object
    }

    private struct NotAnObject: Error {}

    private func assertNoReferences(
        _ value: AnyCodableValue,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        switch value {
        case .object(let object):
            #expect(object["$ref"] == nil, sourceLocation: sourceLocation)
            #expect(object["$defs"] == nil, sourceLocation: sourceLocation)
            for child in object.values {
                try assertNoReferences(child, sourceLocation: sourceLocation)
            }
        case .array(let values):
            for child in values {
                try assertNoReferences(child, sourceLocation: sourceLocation)
            }
        default:
            break
        }
    }

    @Test("a macro-shaped tool input inlines every inner reference")
    func inlinesToolInputSchema() throws {
        let data = try JSONEncoder().encode(DailyInput.generationSchema)
        let schema = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        let inlined = try OllamaEndpoint.inlineSchemaRefs(schema)
        try assertNoReferences(inlined)

        let root = try object(inlined, "root")
        let properties = try object(root["properties"], "properties")
        #expect(properties["days"] != nil)
        #expect(properties["place"] != nil)
        #expect(properties["region"] != nil)
    }

    @Test("a schema without refs passes through unchanged")
    func reflessSchemaIsUnchanged() throws {
        let schema: AnyCodableValue = .object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
        ])
        #expect(try OllamaEndpoint.inlineSchemaRefs(schema) == schema)
    }

    @Test("a $ref without a matching definition is rejected")
    func missingDefinitionThrows() throws {
        let schema: AnyCodableValue = .object([
            "$ref": .string("#/$defs/Gone"),
            "$defs": .object([:]),
        ])
        #expect(throws: OllamaEndpoint.SchemaInliningError.missingDefinition("Gone")) {
            try OllamaEndpoint.inlineSchemaRefs(schema)
        }
    }

    @Test("mutually recursive definitions are rejected")
    func referenceCycleThrows() throws {
        let schema: AnyCodableValue = .object([
            "$ref": .string("#/$defs/A"),
            "$defs": .object([
                "A": .object([
                    "type": .string("object"),
                    "properties": .object(["b": .object(["$ref": .string("#/$defs/B")])]),
                ]),
                "B": .object([
                    "type": .string("object"),
                    "properties": .object(["a": .object(["$ref": .string("#/$defs/A")])]),
                ]),
            ]),
        ])
        #expect(throws: OllamaEndpoint.SchemaInliningError.referenceCycle(["A", "B", "A"])) {
            try OllamaEndpoint.inlineSchemaRefs(schema)
        }
    }
}
