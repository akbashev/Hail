import AnyLanguageModel
import HailCore
import Testing

@testable import HailAgentRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Reasoning loop")
struct ReasoningLoopTests {
    @Test("structured partial model events reach typed stream updates")
    func forwardsStructuredPartialUpdate() {
        let partial = "hel"
        let timestamp = Date(timeIntervalSince1970: 1)

        let updates = TurnReducer.reduce(
            event: ModelEvent<String>.partialUpdated(partial),
            at: timestamp
        )

        guard updates.count == 1,
            case .modelOutputPartialUpdated(let value, let at) = updates[0]
        else {
            Issue.record("Expected one typed partial-output update")
            return
        }

        #expect(value == partial)
        #expect(at == timestamp)
    }

    @Test("a completed tool round carries its content and calls together")
    func forwardsCompletedToolRound() {
        let round = ModelToolRound(
            narration: Transcript.Response(
                assetIDs: [],
                segments: [.text(.init(content: "I will check that."))]
            ),
            reasoning: [.text(.init(content: "Inspecting the request."))],
            calls: [
                ToolCall(
                    id: "call-1",
                    name: "read_file",
                    arguments: GeneratedContent(properties: [:])
                )
            ]
        )
        let updates = TurnReducer.reduce(
            event: ModelEvent<String>.toolsRequested(round),
            at: Date(timeIntervalSince1970: 1)
        )

        guard case .toolRequested(let call, _) = updates.first else {
            Issue.record("Expected the complete tool round to request its tool")
            return
        }
        #expect(call == round.calls[0])
    }
}
