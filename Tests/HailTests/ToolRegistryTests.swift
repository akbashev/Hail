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
