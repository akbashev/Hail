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
        let json = #"{"tool_call_id":"\#(id)","name":"read_file","output":"\#(output)","failure_kind":null}"#
        return try JSONDecoder().decode(ToolResult.self, from: Data(json.utf8))
    }

    @Test("tool events fold with their journaled timestamps, keeping replay deterministic")
    func toolEventsFoldWithJournaledTimestamps() throws {
        let invokedAt = Date(timeIntervalSince1970: 1_000)
        let resultAt = Date(timeIntervalSince1970: 1_042)
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(
            .assistantToolRound(
                content: "",
                thinking: nil,
                calls: [ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}"))],
                at: invokedAt
            )
        )
        state.apply(
            .toolResult(try makeToolResult(id: "call-1", output: "ok"), at: resultAt)
        )

        #expect(state.conversationThread.count == 2)
        #expect(state.conversationThread[0].timestamp == invokedAt)
        #expect(state.conversationThread[1].timestamp == resultAt)
    }

    @Test("a turn without a turn timestamp still folds tool events")
    func preTimingEventsStillFold() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(.turnStarted(at: nil))
        state.apply(
            .assistantToolRound(
                content: "",
                thinking: nil,
                calls: [ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}"))],
                at: Date(timeIntervalSince1970: 1)
            )
        )
        state.apply(.turnCompleted(at: nil))

        #expect(state.conversationThread.count == 1)
        #expect(state.activeTurn == nil)
    }

    @Test("model session events fold id and identity for later resume")
    func modelSessionFolds() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        #expect(state.modelSession == nil)

        state.apply(
            .modelSessionIdentified(id: SessionID("session-1"), identity: SessionIdentity("fp-A")),
        )
        #expect(state.modelSession?.id == SessionID("session-1"))
        #expect(state.modelSession?.identity == SessionIdentity("fp-A"))

        state.apply(
            .modelSessionIdentified(id: SessionID("session-2"), identity: SessionIdentity("fp-B")),
        )
        #expect(state.modelSession?.id == SessionID("session-2"))
        #expect(state.modelSession?.identity == SessionIdentity("fp-B"))
    }

    /// Regression: when the crash happened after tool events, the thread tail
    /// is a tool result, so the old `last != message` fold appended the
    /// re-run's opening a second time. The fold must collapse it against
    /// `pendingTurnRerun` instead.
    @Test("re-run opening collapses even when the crash followed tool events")
    func rerunOpeningCollapsesAfterToolEvents() throws {
        let message = ChatMessage.text(
            sender: "user",
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(.turnStarted(at: Date(timeIntervalSince1970: 1_999)))
        state.apply(.messageReceived(message))
        state.apply(
            .assistantToolRound(
                content: "",
                thinking: nil,
                calls: [ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}"))],
                at: Date(timeIntervalSince1970: 2_001)
            )
        )
        state.apply(
            .toolResult(try makeToolResult(id: "call-1", output: "ok"), at: Date(timeIntervalSince1970: 2_002))
        )
        state.normalizeAfterReplay()

        // The re-run after activation starts a fresh turn and re-journals the
        // exact same opening message (same timestamp).
        state.apply(.turnStarted(at: Date(timeIntervalSince1970: 3_000)))
        state.apply(.messageReceived(message))

        #expect(state.conversationThread.filter { $0 == message }.count == 1)
        #expect(state.activeTurn?.opening == message)
        #expect(state.pendingTurnRerun == nil)
    }

    /// A genuinely repeated message carries a fresh timestamp, so it does not
    /// match the pending re-run marker and must be kept as a duplicate.
    @Test("genuinely repeated message is kept even while a re-run is pending")
    func genuineRepeatIsKept() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        let original = ChatMessage.text(
            sender: "user",
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 2_000)
        )

        state.apply(.turnStarted(at: Date(timeIntervalSince1970: 1_999)))
        state.apply(.messageReceived(original))
        state.apply(
            .assistantToolRound(
                content: "",
                thinking: nil,
                calls: [ToolCall(id: "call-1", name: "read_file", arguments: ToolArguments(json: "{}"))],
                at: Date(timeIntervalSince1970: 2_001)
            )
        )
        state.apply(
            .toolResult(try makeToolResult(id: "call-1", output: "ok"), at: Date(timeIntervalSince1970: 2_002))
        )
        state.normalizeAfterReplay()

        // Same content, fresh timestamp: a real user repeat, not the re-run.
        let repeated = ChatMessage.text(
            sender: "user",
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 3_000)
        )
        state.apply(.turnStarted(at: Date(timeIntervalSince1970: 2_999)))
        state.apply(.messageReceived(repeated))

        let textMessages = state.conversationThread.filter {
            if case .text(let sender, let content, _) = $0 {
                return sender == "user" && content == "hello"
            }
            return false
        }
        #expect(textMessages.count == 2)
        // The repeat consumed the stale re-run marker.
        #expect(state.pendingTurnRerun == nil)
    }

    /// Journals written before turn timing existed encode these cases without
    /// the `at` field; replaying them must still decode and fold.
    @Test("pre-timing journal entries decode with nil timestamps")
    func legacyJournalEntriesDecode() throws {
        let legacyLines = [
            #"{"turnStarted":{}}"#,
            #"{"assistantToolRound":{"content":"","calls":[{"id":"c1","name":"read_file","arguments":{"json":"{}"}}],"at":-978307199.0}}"#,
            #"{"toolResult":{"_0":{"tool_call_id":"c1","name":"read_file","output":"ok","failure_kind":null}}}"#,
            #"{"turnCompleted":{}}"#,
        ]

        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        for line in legacyLines {
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
            state.apply(event)
        }

        #expect(state.conversationThread.count == 2)
        #expect(state.activeTurn == nil)
    }

    @Test("replay normalization clears transient status and interrupts running requests")
    func replayNormalizationInterruptsRunningRequest() throws {
        let turnID = TurnID("turn-crashed")
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let opening = ChatMessage.text(
            sender: "user",
            content: "inspect this",
            timestamp: startedAt
        )
        let record = ModelRequestRecord(
            id: ModelRequestID("request-crashed"),
            turnID: turnID,
            model: "qwen",
            startedAt: startedAt
        )
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        state.apply(.turnStarted(at: startedAt))
        state.apply(.turnIdentified(id: turnID))
        state.apply(.messageReceived(opening))
        state.apply(
            .assistantToolRound(
                content: "",
                thinking: nil,
                calls: [ToolCall(id: "call-crashed", name: "read_file", arguments: ToolArguments(json: "{}"))],
                at: startedAt
            )
        )
        state.apply(.modelRequestStarted(record))

        state.normalizeAfterReplay()

        #expect(state.activeTurn == nil)
        #expect(state.phase == .idle)
        #expect(state.currentToolName == nil)
        #expect(state.pendingTurnRerun == opening)
        #expect(state.modelRequests.first?.outcome == .interrupted)
    }
}
