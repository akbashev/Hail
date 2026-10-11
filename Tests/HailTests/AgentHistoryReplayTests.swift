import AnyLanguageModel
import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Agent history replay")
struct AgentHistoryReplayTests {
    private let agentID = AgentID(role: Role("coder"), contextID: AgentContextID("T-1"))
    private let call = ToolCall(id: "call-1", name: "read_file", arguments: GeneratedContent(properties: [:]))

    private func input(_ text: String, at seconds: TimeInterval = 0) -> AgentHistory.Input {
        AgentHistory.Input(from: .user(id: "u"), content: GeneratedContent(text), at: Date(timeIntervalSince1970: seconds))
    }

    private func replay(_ events: [AgentHistory.Event]) throws -> AgentState {
        try events.reduce(AgentState(agentID: agentID)) { try $0.applying(.history($1)) }
    }

    private func request(_ id: String, kind: ModelRequestKind = .generation) -> AgentEvent {
        .modelRequestStarted(
            ModelRequestRecord(
                id: ModelRequestID(id), turnID: TurnID("t1"), model: "qwen", kind: kind,
                startedAt: Date(timeIntervalSince1970: 3_000)))
    }

    @Test("a turn's steps keep their journaled timestamps, so replay is deterministic")
    func stepsKeepJournaledTimestamps() throws {
        let calledAt = Date(timeIntervalSince1970: 1_000)
        let resultedAt = Date(timeIntervalSince1970: 1_042)
        let result = ToolResult(toolCallID: "call-1", name: "read_file", output: .text("contents"))
        let events: [AgentHistory.Event] = [
            .received(input("read it"), turn: TurnID("t1")),
            .called(call, at: calledAt),
            .resulted(result, at: resultedAt),
            .replied(.init(content: GeneratedContent("done"), at: resultedAt)),
        ]

        let once = try replay(events)
        #expect(once.history == (try replay(events)).history)
        #expect(once.history.closed.first?.steps == [.called(call, at: calledAt), .resulted(result, at: resultedAt)])
        #expect(once.history.open == nil)
    }

    @Test("a turn opens only when none is open")
    func oneOpenTurn() throws {
        let state = try replay([.received(input("one"), turn: TurnID("t1"))])
        #expect(throws: AgentHistory.InvalidEvent.turnStillOpen(TurnID("t1"))) {
            try state.applying(.history(.received(input("two"), turn: TurnID("t2"))))
        }
    }

    @Test("a step or an outcome needs an open turn")
    func stepsNeedAnOpenTurn() {
        #expect(throws: AgentHistory.InvalidEvent.noOpenTurn) {
            try replay([.called(call, at: Date())])
        }
        #expect(throws: AgentHistory.InvalidEvent.noOpenTurn) {
            try replay([.replied(.init(content: GeneratedContent("hi"), at: Date()))])
        }
    }

    @Test("a compaction through a turn the history doesn't have is refused")
    func compactionNeedsAKnownTurn() {
        #expect(throws: AgentHistory.InvalidEvent.unknownTurn(TurnID("nope"))) {
            try replay([
                .compacted(
                    .init(context: GeneratedContent("s"), report: GeneratedContent("s")), through: .after(TurnID("nope")), kept: .all)
            ])
        }
    }

    @Test("the runtime state follows what's open and running")
    func runtimeStateIsDerived() throws {
        var state = try replay([.received(input("go"), turn: TurnID("t1"))])
        #expect(state.runtimeState == .generating)
        try state.apply(request("r1"))
        #expect(state.runtimeState == .generating)
        try state.apply(.history(.called(call, at: Date())))
        #expect(state.runtimeState == .executingTool)
        try state.apply(.history(.failed(.init(error: .contextLengthExceeded, at: Date()))))
        try state.apply(.modelRequestFailed(id: ModelRequestID("r1"), error: .contextLengthExceeded, durationMilliseconds: 1, at: Date()))
        #expect(state.runtimeState == .failed)
        try state.apply(request("r2", kind: .compaction))
        #expect(state.runtimeState == .compacting)
    }

    @Test("a turn still open after replay is the one a crash interrupted, kept for the agent to finish")
    func crashedTurnStaysOpen() throws {
        var state = try replay([
            .received(input("inspect this"), turn: TurnID("turn-crashed")),
            .called(call, at: Date(timeIntervalSince1970: 3_000)),
        ])
        try state.apply(request("request-crashed"))

        state.normalizeAfterReplay()

        #expect(state.history.open?.id == TurnID("turn-crashed"))
        #expect(state.history.open?.steps.count == 1)
        #expect(state.modelRequests.first?.outcome == .interrupted)
    }

    @Test("an interrupted turn the host doesn't resume is closed as interrupted")
    func interruptedTurnCloses() throws {
        let state = try replay([
            .received(input("go"), turn: TurnID("t1")),
            .interrupted(at: Date(timeIntervalSince1970: 5)),
        ])
        #expect(state.history.open == nil)
        #expect(state.history.closed.first?.outcome == .interrupted(at: Date(timeIntervalSince1970: 5)))
        #expect(state.runtimeState == .idle)
    }

    @Test("a compaction folds the turns it covers, keeping the inputs it names")
    func compactionFoldsTurns() throws {
        let state = try replay([
            .received(input("one"), turn: TurnID("t1")), .replied(.init(content: GeneratedContent("1"), at: Date())),
            .received(input("two"), turn: TurnID("t2")), .replied(.init(content: GeneratedContent("2"), at: Date())),
            .received(input("three"), turn: TurnID("t3")),
            .compacted(
                .init(context: GeneratedContent("so far"), report: GeneratedContent("so far")), through: .after(TurnID("t2")),
                kept: .from(TurnID("t2"))),
        ])
        #expect(state.history.earlier?.kept.map(\.turn) == [TurnID("t2")])
        #expect(state.history.closed.isEmpty)
        #expect(state.history.open?.id == TurnID("t3"))
        #expect(state.history.earlier?.summary.context == GeneratedContent("so far"))
    }

    @Test("folding the open turn takes its work and keeps its input")
    func foldingTheOpenTurn() throws {
        let state = try replay([
            .received(input("build it"), turn: TurnID("t1")),
            .called(call, at: Date()),
            .compacted(.init(context: GeneratedContent("s"), report: GeneratedContent("s")), through: .after(TurnID("t1")), kept: .all),
        ])
        #expect(state.history.open?.input == input("build it"))
        #expect(state.history.open?.steps.isEmpty == true)
        #expect(state.history.earlier?.kept.isEmpty == true)
    }

    @Test("model session events fold id and identity for later resume")
    func modelSessionFolds() throws {
        var state = AgentState(agentID: agentID)
        #expect(state.modelSession == nil)

        try state.apply(.modelSessionIdentified(id: SessionID("session-1"), identity: SessionIdentity("fp-A")))
        #expect(state.modelSession?.id == SessionID("session-1"))
        #expect(state.modelSession?.identity == SessionIdentity("fp-A"))

        try state.apply(.modelSessionIdentified(id: SessionID("session-2"), identity: SessionIdentity("fp-B")))
        #expect(state.modelSession?.id == SessionID("session-2"))
        #expect(state.modelSession?.identity == SessionIdentity("fp-B"))
    }
}
