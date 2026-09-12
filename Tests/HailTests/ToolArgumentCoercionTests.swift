import AnyLanguageModel
import Hail
import ScopedEffect
import Testing

@testable import HailCore

@Suite("Tool argument coercion")
struct ToolArgumentCoercionTests {
    @Tool
    struct ForecastTool {
        @Generable
        struct Input: Sendable {
            let place: String
            let days: Int
        }

        let name = "forecast"
        let description = "Forecasts a place."

        var schema: ToolDefinition {
            TestToolDefinition.empty(name: name, description: description)
        }

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> ToolOutput {
            .text("ok \(input.place) \(input.days)")
        }
    }

    @Test("a quoted number is coerced to the declared integer type")
    func quotedNumberIsCoerced() async throws {
        let registry = ToolRegistry()
        await registry.register(ForecastTool())

        let results = try await registry.execute([
            ToolCall(
                id: "call-1",
                name: "forecast",
                arguments: GeneratedContent(properties: [
                    "place": "Haar",
                    "days": "3",
                ])
            )
        ])

        try #require(results.count == 1)
        #expect(!results[0].isError)
        #expect(results[0].output.textRepresentation.contains("ok Haar 3"))
    }

    @Test("a string that does not parse stays a type error")
    func unparseableStringStillFails() async throws {
        let registry = ToolRegistry()
        await registry.register(ForecastTool())

        let results = try await registry.execute([
            ToolCall(
                id: "call-1",
                name: "forecast",
                arguments: GeneratedContent(properties: [
                    "place": "Haar",
                    "days": "three",
                ])
            )
        ])

        try #require(results.count == 1)
        #expect(results[0].isError)
        #expect(results[0].failureKind == .invalidArguments)
        #expect(results[0].output.textRepresentation.contains("wrong JSON type"))
    }
}
