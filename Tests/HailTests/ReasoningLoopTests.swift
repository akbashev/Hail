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

    @Test("a tool call the model makes in its request reaches typed stream updates")
    func forwardsToolCall() {
        let toolCall = ModelToolCall(
            call: ToolCall(
                id: "call-1",
                name: "read_file",
                arguments: GeneratedContent(properties: [:])
            ),
            reply: ToolReply.awaiting().reply
        )
        let updates = TurnReducer.reduce(
            event: ModelEvent<String>.toolCall(toolCall),
            at: Date(timeIntervalSince1970: 1)
        )

        guard case .toolRequested(let call, _) = updates.first else {
            Issue.record("Expected the tool call to be requested")
            return
        }
        #expect(call == toolCall.call)
    }
}
