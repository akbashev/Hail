import AnyLanguageModel
import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Tool registry request stability")
struct ToolRegistryTests {
    @Generable
    struct GenericReport<Summary: Generable, Memory: Generable>: Sendable {
        let summary: Summary
        let memories: [Memory]
    }

    @Generable
    struct GenericSummary: Sendable {
        let text: String
    }

    @Generable
    struct GenericMemory: Sendable {
        let value: String
    }

    @Test("generic generable reports synthesize")
    func genericGenerableReport() throws {
        let content = GeneratedContent(properties: [
            "summary": GeneratedContent(properties: ["text": "done"]),
            "memories": GeneratedContent(elements: [
                GeneratedContent(properties: ["value": "Haar"])
            ]),
        ])
        let report = try GenericReport<GenericSummary, GenericMemory>(content)
        #expect(report.summary.text == "done")
        #expect(report.memories.map { $0.value } == ["Haar"])
    }

    @Test("schemas are sorted independently of registration order")
    func schemasHaveStableOrder() async {
        let registry = ToolRegistry()
        await registry.register(NowTool())
        await registry.register(FileTool(projectRoot: URL(fileURLWithPath: "/tmp")))

        let names = await registry.schemas().map(\.name)

        #expect(names == ["file", "now"])
    }

    struct GeneratedInputTool: HailCore.Tool {
        @Generable
        struct Input: Sendable {
            let message: String
        }

        let name = "generated_input"
        let description = "Echoes generated arguments."

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> ToolOutput {
            .text(input.message)
        }
    }

    @Tool("test")
    struct ParameterlessCommands {
        @Command("ping", description: "Check that the command is reachable.")
        func ping() -> ClockEffect {
            ClockEffect()
        }

        func render(_ date: Date) -> ToolOutput {
            .text(date.ISO8601Format())
        }
    }

    @Test("a call to a tool that doesn't exist lists the tools, with what each does")
    func unknownToolListsTheTools() async throws {
        let registry = ToolRegistry()
        await registry.register(tools: ParameterlessCommands().tools)
        let results = try await registry.execute([
            ToolCall(id: "1", name: "test", arguments: GeneratedContent(properties: [:]))
        ])

        #expect(results[0].failureKind == .rejected)
        #expect(
            results[0].output.textRepresentation
                == "Error: There's no tool `test`. The tools are:\n- test_ping: Check that the command is reachable.")
    }

    @Test("parameterless commands receive an empty generated input")
    func parameterlessCommand() async throws {
        let tool = ParameterlessCommands.PingTool(owner: ParameterlessCommands())

        #expect(tool.description == "Check that the command is reachable.")
        let output = try await AnyTool(tool).runOutput(
            generatedContent: GeneratedContent(properties: [:]),
            authority: FullAuthority()
        )
        #expect(!output.textRepresentation.isEmpty)
    }

    @Test("generated arguments are decoded without a JSONDecoder round trip")
    func generatedArgumentsExecute() async throws {
        let tool = AnyTool(GeneratedInputTool())
        let generated = GeneratedContent(properties: ["message": "hello"])
        let output = try await tool.runOutput(
            generatedContent: generated,
            authority: FullAuthority()
        )

        #expect(output == .text("hello"))
    }
}

extension ToolRegistryTests {
    @Generable
    struct Plan {
        @Generable
        enum Verb: String { case add, reply }
        @Generable
        struct Step {
            let action: Verb
            let value: String?
        }
        let name: String
        let start: String?
        let steps: [Step]
    }

    /// Small models send a nested argument as JSON text, and numbers where text was asked for;
    /// both are read as the schema asks. Text inside stays text.
    @Test("arguments are brought to the schema's shape")
    func argumentsAreConformed() throws {
        let plan = try Plan(
            leniently: try GeneratedContent(
                json: #"{"name": "n", "start": "[]", "steps": "[{\"action\": \"add\", \"value\": 1}, {\"action\": \"reply\", \"value\": \"[]\"}]"}"#))
        #expect(plan.start == "[]")
        #expect(plan.steps.map(\.value) == ["1", "[]"])
        // A list where text was asked for is read as its JSON text.
        #expect(try Plan(leniently: try GeneratedContent(json: #"{"name": "n", "start": [], "steps": []}"#)).start == "[]")
    }

    /// What doesn't fit is named by its path, with what it should be.
    @Test("a mismatch names its path")
    func mismatchesNameTheirPath() throws {
        func error(_ json: String) -> String {
            do {
                _ = try Plan(leniently: try GeneratedContent(json: json))
                return ""
            } catch {
                return String(describing: error)
            }
        }
        #expect(
            error(#"{"name": "n", "steps": [{"action": "add"}, {"reply": "x"}]}"#)
                == "`steps[1]` needs `action`, one of add, reply; `reply` isn't one of its parts. Its parts: action, value.")
        #expect(
            error(#"{"name": "n", "steps": [{"action": "filter"}]}"#)
                == "`steps[0].action` is `filter`, but it's one of add, reply.")
        #expect(error(#"{"name": "n", "steps": "add"}"#) == #"`steps` is `"add"`, but it's a list."#)
        #expect(error(#"{"name": "n", "steps": "[{\"action\": \"reply\", \"value\": \"a\" + b}]"}"#).hasPrefix("`steps` is JSON text that doesn't read"))
    }
}

extension ToolRegistryTests {
    @Generable
    struct Outer {
        @Generable
        struct Value { let text: String }
        @Generable
        struct Other {
            @Generable
            struct Value { let count: Int }
            let value: Value
        }
        let value: Value
        let other: Other
    }

    /// A tool's schema names each definition by its last part, numbering only a clash, and its
    /// references follow.
    @Test("definitions are named short, references follow")
    func definitionsAreNamedShort() throws {
        let schema = ToolDefinition(name: "t", description: "", parameters: Outer.generationSchema).parameters
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
        let definitions = try #require(json["$defs"] as? [String: Any])
        #expect(Set(definitions.keys) == ["Outer", "Other", "Value", "Value2"])
        let text = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        #expect(!text.contains("ToolRegistryTests."))
        // Arguments still decode with the shortened schema.
        let content = try GeneratedContent(json: #"{"value": {"text": "a"}, "other": {"value": {"count": 1}}}"#)
        #expect(try Outer(content).other.value.count == 1)
    }
}
