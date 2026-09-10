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

        func run(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> String {
            input.message
        }
    }

    @Tool("test")
    struct ParameterlessCommands {
        @Command("ping", description: "Check that the command is reachable.")
        func ping() -> ClockEffect {
            ClockEffect()
        }

        func render(_ date: Date) -> String {
            date.ISO8601Format()
        }
    }

    @Test("parameterless commands receive an empty generated input")
    func parameterlessCommand() async throws {
        let tool = ParameterlessCommands.PingTool(owner: ParameterlessCommands())

        #expect(tool.description == "Check that the command is reachable.")
        let output = try await AnyTool(tool).run(
            generatedContent: GeneratedContent(properties: [:]),
            authority: FullAuthority()
        )
        #expect(!output.isEmpty)
    }

    @Test("generated arguments are decoded without a JSONDecoder round trip")
    func generatedArgumentsExecute() async throws {
        let tool = AnyTool(GeneratedInputTool())
        let generated = GeneratedContent(properties: ["message": "hello"])
        let output = try await tool.run(
            generatedContent: generated,
            authority: FullAuthority()
        )

        #expect(output == "hello")
    }
}
