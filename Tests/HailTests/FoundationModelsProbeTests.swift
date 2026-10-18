import AnyLanguageModel
import HailCore
import ScopedEffect
import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Temporary live probe: runs the real on-device FoundationModels model
/// through AnyLanguageModelEndpoint with a tool whose input mirrors
/// Norby's TimerToolsCreateAtInput (simple string enum + optional message +
/// clock fields). Dumps the parameters schema JSON and every ModelEvent so
/// we can see exactly what schema the model receives and what it emits.
@Suite("FoundationModels live probe")
struct FoundationModelsProbeTests {
    @AnyLanguageModel.Generable
    enum ProbeAction: Sendable {
        case deliverPreparedMessage
        case performTask
    }

    @AnyLanguageModel.Generable
    struct ProbeInput: Sendable {
        public let action: ProbeAction
        public let message: String?
        public let hour: Int
        public let minute: Int
        public let timeZone: String
    }

    private struct ProbeTool: HailCore.Tool {
        let name = "probe_reminder"
        let description = "Sets a reminder at an exact clock time."

        func effect(for input: ProbeInput) throws -> ClockEffect {
            ClockEffect()
        }

        func run(_ input: ProbeInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>) async throws -> CallReturn {
            .text("scheduled")
        }
    }

    @Test("the on-device model counts a request's tokens, its tools included")
    func countsTokens() async throws {
        guard case .available = await AnyLanguageModel.SystemLanguageModel.default.availability else { return }
        let endpoint = AnyLanguageModelEndpoint.system(model: "on-device", temperature: 0.2, contextWindow: 4096)
        guard case .available(let count) = endpoint.tokenCounting else {
            Issue.record("Expected the on-device model to count tokens")
            return
        }
        let entries: [AnyLanguageModel.Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: "You set reminders."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Remind me at 11:00 to call home."))])),
        ]
        let tool = ToolDefinition(
            name: "probe_reminder", description: "Sets a reminder at an exact clock time.",
            parameters: ProbeInput.generationSchema)
        let withoutTools = try await count(entries, [])
        let withTools = try await count(entries, [tool])
        let toolsAlone = try await count([], [tool])
        #expect(withoutTools > 0)
        #expect(withTools > withoutTools)
        #expect(toolsAlone > 0)
    }

    @Test("live probe of enum tool argument through the on-device model")
    func probe() async throws {
        let availability = await AnyLanguageModel.SystemLanguageModel.default.availability
        guard case .available = availability else {
            print("PROBE SKIP: system model unavailable:", String(describing: availability))
            return
        }

        let schemaData = try JSONEncoder().encode(ProbeInput.generationSchema)
        print("PROBE SCHEMA:", String(data: schemaData, encoding: .utf8) ?? "<n/a>")

        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SystemLanguageModel.default,
            modelIdentifier: "on-device",
            temperature: 0.2,
            failures: .swiftErrors
        )
        let entries: [AnyLanguageModel.Transcript.Entry] = [
            .prompt(
                .init(segments: [
                    .text(
                        .init(
                            content:
                                "Set a reminder at 11:00 to ask the kids to finish watching iPads. Use the probe_reminder tool."
                        ))
                ]))
        ]
        for await event in endpoint.stream(
            request: ModelRequest(input: "x", entries: entries),
            tools: [AnyTool(ProbeTool())],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            print("PROBE EVENT:", String(describing: event))
            // Answered as the agent's session would.
            if case .toolCall(let toolCall) = event {
                toolCall.reply.give(
                    ToolAnswer(
                        result: ToolResult(toolCallID: toolCall.call.id, name: toolCall.call.name, output: .text("Reminder set.")),
                        tools: [AnyTool(ProbeTool())]))
            }
        }
    }
}
