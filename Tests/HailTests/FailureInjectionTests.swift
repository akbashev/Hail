import AnyLanguageModel
import Foundation
import Hail
import ScopedEffect
import Testing

@testable import HailModelRuntime

#if canImport(Darwin)
    import Darwin
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#endif

/// Failure-injection coverage for Hail-owned failure modes: repeated crash
/// recovery at the `AgentState` fold, and the journal decode boundary.
///
/// Cluster-level failures (downed EventStore singleton, agent-process kill
/// with virtual-actor reactivation, multi-node failover) are deliberately out
/// of scope here: they need a real cluster.

// MARK: - Repeated crash (AgentState fold)

/// A crashed turn stays open and the agent finishes it: what the resumed run does lands in the
/// same turn, however often it crashes, and its input is never journaled again.
@Suite("AgentState repeated crash")
struct RepeatedCrashTests {
    @Test("a turn resumed after two crashes is still one turn with all its work")
    func repeatedCrashKeepsOneTurn() throws {
        let call = { (id: String) in ToolCall(id: id, name: "read_file", arguments: GeneratedContent(properties: [:])) }
        let result = { (id: String) in ToolResult(toolCallID: id, name: "read_file", output: .text("ok")) }
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        let input = AgentHistory.Input(
            content: GeneratedContent("hello"), at: Date(timeIntervalSince1970: 2_000))

        try state.apply(.history(.received(input, turn: TurnID("t1"))))
        for (round, id) in ["call-1", "call-2"].enumerated() {
            let at = Date(timeIntervalSince1970: 2_001 + TimeInterval(round))
            try state.apply(.history(.called(call(id), at: at)))
            try state.apply(.history(.resulted(result(id), at: at)))
            state.normalizeAfterReplay()
            #expect(state.history.open?.id == TurnID("t1"))
        }
        try state.apply(
            .history(.replied(.init(content: GeneratedContent("done"), at: Date(timeIntervalSince1970: 4_100)))))

        #expect(state.history.closed.count == 1)
        #expect(state.history.closed[0].steps.count == 4)
        #expect(state.history.open == nil)
    }
}

// MARK: - Corrupted journal tail (decode boundary)

/// The journal decode boundary Hail owns: replay folds events one at a time,
/// so a corrupted tail event fails loudly at `JSONDecoder` and never
/// partially applies — replay through the last valid event recovers the
/// exact pre-crash state. Torn-line *framing* (skipping or repairing a
/// partial final JSONL line) is the EventStore's job, and the store is
/// bring-your-own (stagehand's `FileEventStore` lives outside this package);
/// what Hail owns — the `AgentEvent` decode + `AgentState` fold — is pinned
/// here as loud. In the session-resume path a malformed entry therefore
/// throws during replay, before any `ModelSessionResume` can be constructed
/// from partial state.
@Suite("Corrupted journal tail")
struct CorruptedJournalTests {
    private func encode(_ event: AgentEvent) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    private func makeToolResult(id: String, output: String) throws -> ToolResult {
        ToolResult(toolCallID: id, name: "read_file", output: .text(output))
    }

    @Test("a torn tail event throws and never partially applies")
    func tornTailThrowsAndKeepsState() throws {
        let input = AgentHistory.Input(
            content: GeneratedContent("hello"), at: Date(timeIntervalSince1970: 2_000))
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        let validLines = [
            try encode(.history(.received(input, turn: TurnID("t1")))),
            try encode(
                .history(
                    .called(
                        ToolCall(id: "call-1", name: "read_file", arguments: GeneratedContent(properties: [:])),
                        at: Date(timeIntervalSince1970: 2_001)))),
        ]
        for line in validLines {
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
            try state.apply(event)
        }
        let beforeTail = state.history
        #expect(beforeTail.open?.steps.count == 1)

        // A crash mid-write leaves a torn final line: a valid prefix of a
        // real event, cut before the JSON closes.
        let tailEvent = try encode(
            .history(.resulted(try makeToolResult(id: "call-1", output: "ok"), at: Date(timeIntervalSince1970: 2_002)))
        )
        let torn = String(tailEvent.prefix(tailEvent.count / 2))
        #expect {
            _ = try JSONDecoder().decode(AgentEvent.self, from: Data(torn.utf8))
        } throws: { error in
            error is DecodingError
        }

        // Syntactically valid JSON that names no known event is just as loud.
        #expect {
            _ = try JSONDecoder().decode(AgentEvent.self, from: Data(#"{"bogusEvent":{"_0":1}}"#.utf8))
        } throws: { error in
            error is DecodingError
        }

        // The failed decodes never touched the state: replay through the
        // last valid event recovers the exact pre-crash state, with the
        // interrupted turn still open for the agent to finish.
        state.normalizeAfterReplay()
        #expect(state.history == beforeTail)
    }
}
