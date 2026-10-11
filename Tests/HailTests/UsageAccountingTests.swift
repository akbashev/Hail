import AnyLanguageModel
import Foundation
import HailCore
import Testing

@Suite("Usage accounting")
struct UsageAccountingTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("usage"))

    @Test("usage events fold into durable totals without touching the transcript")
    func usageFoldsIntoState() throws {
        var state = AgentState(agentID: agentID)
        let usage = ModelUsage(
            inputTokens: 10,
            outputTokens: 4,
            reasoningTokens: 2,
            totalTokens: 14,
            source: .reported
        )
        try state.apply(.modelUsage(usage, at: Date()))
        try state.apply(
            .contextUsage(ContextUsage(usedTokens: 12, limitTokens: 100, source: .reported), at: Date())
        )

        #expect(state.history.closed.isEmpty)
        #expect(state.usageSummary.requestCount == 1)
        #expect(state.usageSummary.inputTokens == 10)
        #expect(state.usageSummary.outputTokens == 4)
        #expect(state.usageSummary.reasoningTokens == 2)
        #expect(state.usageSummary.totalTokens == 14)
        #expect(state.latestContextUsage?.usedTokens == 12)
    }

    @Test("request lifecycle is replayable and queryable")
    func requestLifecycleProjection() throws {
        let turnID = TurnID("turn-1")
        let requestID = ModelRequestID("request-1")
        let startedAt = Date(timeIntervalSince1970: 1)
        let completedAt = Date(timeIntervalSince1970: 2)
        let record = ModelRequestRecord(
            id: requestID,
            turnID: turnID,
            model: "qwen",
            startedAt: startedAt
        )
        let usage = ModelUsage(inputTokens: 8, outputTokens: 3, totalTokens: 11, source: .reported)
        let events: [AgentEvent] = [
            .history(
                .received(.init(from: .user(id: "u"), content: GeneratedContent("go"), at: startedAt), turn: turnID)),
            .modelRequestStarted(record),
            .modelUsage(usage, at: completedAt),
            .modelRequestCompleted(
                id: requestID,
                usage: usage,
                durationMilliseconds: 1_000,
                at: completedAt
            ),
        ]

        var state = AgentState(agentID: agentID)
        for event in events { try state.apply(event) }

        #expect(state.history.open?.id == turnID)
        #expect(state.runtimeState == .generating)
        #expect(state.modelRequests.count == 1)
        #expect(state.modelRequests.first?.outcome == .completed)
        #expect(state.modelRequests.first?.durationMilliseconds == 1_000)

        let journal = AgentJournalReader(events: events)
        #expect(journal.modelRequests == state.modelRequests)
    }

    @Test("the actor-local request projection stays bounded")
    func recentRequestProjectionIsBounded() throws {
        var state = AgentState(agentID: agentID)
        for index in 0..<105 {
            try state.apply(
                .modelRequestStarted(
                    ModelRequestRecord(
                        id: ModelRequestID("request-\(index)"),
                        turnID: TurnID("turn-\(index)"),
                        model: "qwen",
                        startedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                )
            )
        }

        #expect(state.modelRequests.count == 100)
        #expect(state.modelRequests.first?.id == ModelRequestID("request-5"))
        #expect(state.modelRequests.last?.id == ModelRequestID("request-104"))
    }
}
