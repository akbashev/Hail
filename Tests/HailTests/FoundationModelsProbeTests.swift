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

        func runOutput(
            input: ProbeInput,
            token: borrowing EffectToken<ClockEffect>
        ) async throws -> ToolOutput {
            .text("scheduled")
        }
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
            temperature: 0.2
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
        }
    }
}
