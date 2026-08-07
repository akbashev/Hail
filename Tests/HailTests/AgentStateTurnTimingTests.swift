import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("AgentStateTurnTiming")
struct AgentStateTurnTimingTests {
    private func makeToolResult(id: String, output: String) throws -> ToolResult {
        let json = #"{"tool_call_id":"\#(id)","name":"read_file","output":"\#(output)","is_error":false}"#
        return try JSONDecoder().decode(ToolResult.self, from: Data(json.utf8))
    }

    @Test("tool events fold with their journaled timestamps, keeping replay deterministic")
    func toolEventsFoldWithJournaledTimestamps() throws {
        let invokedAt = Date(timeIntervalSince1970: 1_000)
        let resultAt = Date(timeIntervalSince1970: 1_042)
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(
            .toolInvoked(
                ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}")),
                at: invokedAt
            ),
            maxMemoryFragments: 10
        )
        state.apply(
            .toolResult(try makeToolResult(id: "call-1", output: "ok"), at: resultAt),
            maxMemoryFragments: 10
        )

        #expect(state.conversationThread.count == 2)
        #expect(state.conversationThread[0].timestamp == invokedAt)
        #expect(state.conversationThread[1].timestamp == resultAt)
    }

    @Test("pre-timing events (nil timestamps) still fold")
    func preTimingEventsStillFold() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(.turnStarted(at: nil), maxMemoryFragments: 10)
        state.apply(
            .toolInvoked(
                ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}")),
                at: nil
            ),
            maxMemoryFragments: 10
        )
        state.apply(.turnCompleted(at: nil), maxMemoryFragments: 10)

        #expect(state.conversationThread.count == 1)
        #expect(state.activeTurn == nil)
    }

    @Test("model session events fold id and identity for later resume")
    func modelSessionFolds() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        #expect(state.modelSessionID == nil)

        state.apply(
            .modelSessionIdentified(id: SessionID("session-1"), identity: SessionIdentity("fp-A")),
            maxMemoryFragments: 10
        )
        #expect(state.modelSessionID == SessionID("session-1"))
        #expect(state.modelSessionIdentity == SessionIdentity("fp-A"))

        state.apply(
            .modelSessionIdentified(id: SessionID("session-2"), identity: SessionIdentity("fp-B")),
            maxMemoryFragments: 10
        )
        #expect(state.modelSessionID == SessionID("session-2"))
        #expect(state.modelSessionIdentity == SessionIdentity("fp-B"))
    }

    /// Journals written before turn timing existed encode these cases without
    /// the `at` field; replaying them must still decode and fold.
    @Test("pre-timing journal entries decode with nil timestamps")
    func legacyJournalEntriesDecode() throws {
        let legacyLines = [
            #"{"turnStarted":{}}"#,
            #"{"toolInvoked":{"_0":{"id":"c1","name":"read_file","arguments":{"json":"{}"}}}}"#,
            #"{"toolResult":{"_0":{"tool_call_id":"c1","name":"read_file","output":"ok","is_error":false}}}"#,
            #"{"turnCompleted":{}}"#,
        ]

        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        for line in legacyLines {
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
            state.apply(event, maxMemoryFragments: 10)
        }

        #expect(state.conversationThread.count == 2)
        #expect(state.activeTurn == nil)
    }
}
