import AnyLanguageModel
import Testing

@testable import HailModelRuntime

/// Ollama builds its sampling grammar from the request's `format` schema,
/// but its builder resolves a `$ref` only at the schema root: a `$ref`
/// inside `properties` — the shape `@Generable` emits for nested types —
/// makes it silently fall back to unconstrained sampling. `outputSchema`
/// must inline every local ref so the declared output contract is what the
/// provider actually enforces.
@Suite("Ollama schema inlining")
struct OllamaSchemaInliningTests {
    private struct NotAnObject: Error {}

    @Generable
    struct Report: Codable, Sendable {
        @Generable
        struct Summary: Codable, Sendable {
            let keyPoints: [String]
            let openThreads: [String]
        }
        @Generable
        struct MemoryCandidate: Codable, Sendable {
            let namespace: String
            let predicate: String
            let value: String
            let confidence: Double
            let supportingText: String
        }
        let summary: Summary
        let memories: [MemoryCandidate]
    }

    private func object(
        _ value: AnyCodableValue?,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: AnyCodableValue] {
        guard case .object(let object)? = value else {
            Issue.record("Expected an object at \(label)", sourceLocation: sourceLocation)
            throw NotAnObject()
        }
        return object
    }

    private func assertNoRefs(
        _ value: AnyCodableValue,
        path: String = "$",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        switch value {
        case .object(let object):
            #expect(object["$ref"] == nil, "\(path) still carries a $ref", sourceLocation: sourceLocation)
            #expect(object["$defs"] == nil, "\(path) still carries $defs", sourceLocation: sourceLocation)
            for (key, child) in object {
                try assertNoRefs(child, path: "\(path).\(key)", sourceLocation: sourceLocation)
            }
        case .array(let values):
            for (index, child) in values.enumerated() {
                try assertNoRefs(child, path: "\(path)[\(index)]", sourceLocation: sourceLocation)
            }
        default:
            break
        }
    }

    @Test("a macro-shaped nested schema inlines every $ref")
    func inlinesNestedReportSchema() throws {
        let schema = try OllamaEndpoint.outputSchema(for: Report.self)
        try assertNoRefs(schema)

        let root = try object(schema, "root")
        #expect(root["type"] == .string("object"))
        let properties = try object(root["properties"], "properties")
        let summary = try object(properties["summary"], "summary")
        let summaryProperties = try object(summary["properties"], "summary.properties")
        #expect(summaryProperties["keyPoints"] != nil)
        #expect(summaryProperties["openThreads"] != nil)
        let memories = try object(properties["memories"], "memories")
        let item = try object(memories["items"], "memories.items")
        let itemProperties = try object(item["properties"], "memories.items.properties")
        #expect(itemProperties["namespace"] != nil)
        #expect(itemProperties["supportingText"] != nil)
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

    @Test("a $ref outside the document is rejected")
    func externalReferenceThrows() throws {
        let schema: AnyCodableValue = .object([
            "$ref": .string("https://example.com/schema.json#Thing")
        ])
        #expect(throws: OllamaEndpoint.SchemaInliningError.externalReference("https://example.com/schema.json#Thing")) {
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
                    "properties": .object([
                        "b": .object(["$ref": .string("#/$defs/B")])
                    ]),
                ]),
                "B": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "a": .object(["$ref": .string("#/$defs/A")])
                    ]),
                ]),
            ]),
        ])
        #expect(throws: OllamaEndpoint.SchemaInliningError.referenceCycle(["A", "B", "A"])) {
            try OllamaEndpoint.inlineSchemaRefs(schema)
        }
    }
}
