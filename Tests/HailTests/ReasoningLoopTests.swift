import Foundation
import HailCore
import Testing

@testable import HailAgentRuntime

@Suite("Reasoning loop")
struct ReasoningLoopTests {
    @Test("structured partial model events reach typed stream updates")
    func forwardsStructuredPartialUpdate() {
        let partial = ChatResponse(content: "hel")
        let timestamp = Date(timeIntervalSince1970: 1)

        let (state, updates) = TurnReducer.reduce(
            state: .idle,
            event: ModelEvent<ChatResponse>.partialUpdated(partial),
            at: timestamp
        )

        guard case .idle = state else {
            Issue.record("A partial update must not change the turn state")
            return
        }
        guard updates.count == 1,
              case .run(.event(.modelOutputPartialUpdated(let value, let at))) = updates[0]
        else {
            Issue.record("Expected one typed partial-output update")
            return
        }

        #expect(value == partial)
        #expect(at == timestamp)
    }
}
