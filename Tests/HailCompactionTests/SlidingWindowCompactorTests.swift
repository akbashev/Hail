import AnyLanguageModel
import HailAgentRuntime
import HailCore
import Synchronization
import Testing

@testable import HailCompaction

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("SlidingWindowCompactor")
struct SlidingWindowCompactorTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("c1"))

    // MARK: Helpers

    /// A turn as the model made it: what was said, each call with its result, then the answer;
    /// open when there's no answer.
    private struct Exchange {
        let said: String
        var work: [(name: String, result: String)] = []
        var answer: String? = "ok"
    }

    private func history(_ exchanges: [Exchange], summary: String? = nil) throws -> (AgentHistory, [TurnID]) {
        var history = AgentHistory()
        if let summary {
            let earlier = TurnID()
            history =
                try history
                .applying(
                    .received(
                        .init(from: .user(id: "u"), content: GeneratedContent("before"), at: Date()), turn: earlier)
                )
                .applying(.replied(.init(content: GeneratedContent("ok"), at: Date())))
                .applying(
                    .compacted(
                        .init(context: GeneratedContent(summary), report: GeneratedContent(summary)),
                        through: .after(earlier), kept: .none))
        }
        var ids: [TurnID] = []
        for (index, exchange) in exchanges.enumerated() {
            let id = TurnID()
            ids.append(id)
            let at = Date(timeIntervalSince1970: TimeInterval(index))
            history = try history.applying(
                .received(
                    AgentHistory.Input(from: .user(id: "u"), content: GeneratedContent(exchange.said), at: at), turn: id
                ))
            for (step, work) in exchange.work.enumerated() {
                let call = ToolCall(
                    id: "\(index)-\(step)", name: work.name, arguments: GeneratedContent(properties: [:]))
                history = try history.applying(.called(call, at: at))
                history = try history.applying(
                    .resulted(ToolResult(toolCallID: call.id, name: work.name, output: .text(work.result)), at: at))
            }
            if let answer = exchange.answer {
                history = try history.applying(.replied(AgentHistory.Reply(content: GeneratedContent(answer), at: at)))
            }
        }
        return (history, ids)
    }

    private func context(_ history: AgentHistory) throws -> PromptContext {
        PromptContext(
            agentID: agentID,
            definition: AgentDefinition(role: agentID.role, behavior: .init(systemPrompt: "sys")),
            modelConfiguration: ModelConfiguration(model: try AgentModel("test/fake")),
            history: history,
            contextManifest: ContextManifest(items: [])
        )
    }

    private func text(in entry: Transcript.Entry) -> String {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let value): segments = value.segments
        case .prompt(let value): segments = value.segments
        case .response(let value): segments = value.segments
        case .toolOutput(let value): segments = value.segments
        case .toolCalls, .reasoning: return ""
        }
        return segments.map { segment in
            switch segment {
            case .text(let value): value.content
            case .structure(let value): value.content.jsonString
            case .image: "[image]"
            }
        }.joined(separator: "\n")
    }

    private func requireCompaction(
        _ decision: CompactionDecision<String>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CompactionResult<String> {
        guard case .compacted(let compaction) = decision else {
            Issue.record("Expected a compaction decision", sourceLocation: sourceLocation)
            throw TestFailure()
        }
        return compaction
    }

    /// A 15% threshold with 400 tokens reserved for the summary; the window is the budget's.
    /// The most recent history kept within 11% of the window: two of these turns of about 200
    /// tokens each, on 4,000 tokens.
    private func makeCompactor(
        keepRecentShare: Double = 0.11, outputReserve: Int = 400, keptInputsShare: Double = 0.2
    ) -> SlidingWindowCompactor {
        SlidingWindowCompactor(
            threshold: 0.15, keepRecentShare: keepRecentShare, outputReserve: outputReserve, toolResultReserve: 0,
            keptInputsShare: keptInputsShare)
    }

    private func budget(_ window: Int = 4_000) throws -> CompactionBudget {
        try CompactionBudget(contextWindow: window)
    }

    private func fiveTurns() throws -> (AgentHistory, [TurnID]) {
        try history((0..<5).map { Exchange(said: "message \($0) " + String(repeating: "a", count: 790)) })
    }

    // MARK: When

    @Test("a context under the threshold compacts nothing")
    func underThresholdNoCompaction() async throws {
        let (history, _) = try history([Exchange(said: "hi"), Exchange(said: "hello")])
        let ctx = try context(history)
        let result = try await makeCompactor().compact(
            context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()
        ) { _ in "unused" }
        #expect(result == .unchanged)
    }

    @Test("past the threshold, a history that fits its share whole is left as it is")
    func smallConversationUnchangedPastThreshold() async throws {
        let (history, _) = try history([Exchange(said: "one"), Exchange(said: "two")])
        let ctx = try context(history)
        let result = try await makeCompactor().compact(
            context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(),
            measuring: .reportedFloor(RequestMeasurement(tokenCount: 900, source: .reported)),
            summarize: { _ in "rolled" }, trigger: .threshold)
        #expect(result == .unchanged)
    }

    // MARK: What folds

    @Test("past the threshold, the oldest turns fold and the most recent stay whole, within their share")
    func foldsOldestKeepingRecent() async throws {
        let (history, ids) = try fiveTurns()
        let ctx = try context(history)
        let result = try requireCompaction(
            await makeCompactor().compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()
            ) { _ in "rolled" })
        #expect(result.through == .after(ids[2]))
        let after = try history.applying(
            .compacted(
                .init(context: GeneratedContent("rolled"), report: GeneratedContent("rolled")), through: result.through,
                kept: result.kept))
        #expect(after.closed.map(\.id) == Array(ids[3...]))
    }

    @Test("a bigger window keeps more of the same history whole")
    func keptHistoryScalesWithTheWindow() async throws {
        let (history, ids) = try fiveTurns()
        let ctx = try context(history)
        func cut(_ window: Int) async throws -> AgentHistory.Cut {
            try requireCompaction(
                await makeCompactor().compact(
                    context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(window),
                    measuring: .reportedFloor(RequestMeasurement(tokenCount: window, source: .reported)),
                    summarize: { _ in "rolled" }, trigger: .contextLengthExceeded)
            ).through
        }
        #expect(try await cut(4_000) == .after(ids[2]))
        #expect(try await cut(40_000) == .after(ids[0]))
    }

    @Test("what was said stays word for word, newest first, within its share of the window")
    func inputsStayWithinTheirShare() async throws {
        let (history, ids) = try history((0..<5).map { _ in Exchange(said: String(repeating: "b", count: 800)) })
        let ctx = try context(history)
        func kept(_ share: Double) async throws -> AgentHistory.KeptInputs {
            try requireCompaction(
                await makeCompactor(keptInputsShare: share).compact(
                    context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()
                ) { _ in "rolled" }
            ).kept
        }
        // Each input costs 200 tokens of the 4,000-token window; the fold archives turns 0 to 2.
        #expect(try await kept(0.2) == .all)
        #expect(try await kept(0.1) == .from(ids[1]))
        #expect(try await kept(0.02) == .none)
    }

    @Test("an overflow cuts inside the open turn: its latest work stays, and its input stays first")
    func overflowFoldsTheOpenTurn() async throws {
        let (history, ids) = try history([
            Exchange(
                said: "build it", work: (0..<4).map { ("step", String(repeating: "x", count: 1_000) + "\($0)") },
                answer: nil)
        ])
        let ctx = try context(history)
        let captured = Box<[Transcript.Entry]>()
        let result = try requireCompaction(
            await makeCompactor().compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(),
                measuring: .reportedFloor(RequestMeasurement(tokenCount: 1_200, source: .reported)),
                summarize: { request in
                    captured.value = request.entries
                    return "rolled"
                },
                trigger: .contextLengthExceeded))
        // Each result is about 250 tokens: the last call and its result fit 11% of 4,000.
        #expect(result.through == .within(ids[0], steps: 6))
        let after = try history.applying(
            .compacted(
                .init(context: GeneratedContent("rolled"), report: GeneratedContent("rolled")), through: result.through,
                kept: result.kept))
        #expect(after.open?.steps.count == 2)
        let request = assembleStandardPrompt(try context(after))
        #expect(request.openTurn.first.map(text(in:)) == "build it")
        #expect(captured.value?.map(text(in:)).joined().contains("This turn so far, still in progress:") == true)
    }

    @Test("an overflow compacts even a conversation smaller than it keeps")
    func overflowCompactsSmallConversations() async throws {
        let (history, _) = try history((0..<3).map { _ in Exchange(said: String(repeating: "c", count: 1_000)) })
        let ctx = try context(history)
        _ = try requireCompaction(
            await makeCompactor().compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(8_000),
                measuring: .reportedFloor(RequestMeasurement(tokenCount: 7_000, source: .reported)),
                summarize: { _ in "rolled" }, trigger: .contextLengthExceeded))
    }

    // MARK: The summary

    @Test("the summary so far is folded into the summary prompt")
    func priorSummaryInPrompt() async throws {
        let (history, _) = try history(
            (0..<5).map { Exchange(said: "message \($0) " + String(repeating: "a", count: 790)) },
            summary: "earlier facts")
        let ctx = try context(history)
        let captured = Box<[Transcript.Entry]>()
        _ = try requireCompaction(
            await makeCompactor().compact(context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()) {
                request in
                captured.value = request.entries
                return "rolled"
            })
        #expect(captured.value?.map(text(in:)).joined().contains("earlier facts") == true)
    }

    @Test("oversized tool results are excerpted in the summary prompt")
    func oversizedResultsExcerpted() async throws {
        // The turn being worked on read something large, then something small: the large result
        // is folded, and the summarizer gets an excerpt of it.
        var exchanges = (0..<4).map { Exchange(said: "message \($0) " + String(repeating: "a", count: 40)) }
        exchanges[3].work = [("read", String(repeating: "r", count: 5_000)), ("read", "small")]
        exchanges[3].answer = nil
        let (history, _) = try history(exchanges)
        let ctx = try context(history)
        let captured = Box<[Transcript.Entry]>()
        _ = try requireCompaction(
            await makeCompactor(keepRecentShare: 0.05).compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(8_000),
                measuring: .reportedFloor(RequestMeasurement(tokenCount: 7_000, source: .reported)),
                summarize: { request in
                    captured.value = request.entries
                    return "rolled"
                }, trigger: .threshold))
        #expect(captured.value?.map(text(in:)).joined().contains("…[truncated]") == true)
    }

    @Test("the summarizer is capped by the budget it has")
    func summarizerCapped() async throws {
        let (history, _) = try fiveTurns()
        let ctx = try context(history)
        let captured = Box<Int>()
        _ = try requireCompaction(
            await makeCompactor(outputReserve: 300).compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()
            ) {
                request in
                captured.value = request.maxOutputTokens
                return "rolled"
            })
        #expect((captured.value ?? .max) <= 300)
    }

    @Test("the task instruction is the built-in summary task")
    func taskInstructionIsTheBuiltInSummaryTask() async throws {
        let (history, _) = try fiveTurns()
        let ctx = try context(history)
        let captured = Box<[Transcript.Entry]>()
        _ = try requireCompaction(
            await makeCompactor().compact(context: ctx, request: assembleStandardPrompt(ctx), budget: try budget()) {
                request in
                captured.value = request.entries
                return "rolled"
            })
        let instruction = try #require(captured.value?.first).map(text(in:)) ?? ""
        #expect(instruction.contains("Rewrite the"))
        #expect(instruction.contains("fit within"))
    }

    // MARK: Fitting

    @Test("the endpoint's token counter is used to fit candidates")
    func endpointCounterFitsCandidates() async throws {
        let (history, _) = try fiveTurns()
        let ctx = try context(history)
        let measured = Box<Int>()
        _ = try requireCompaction(
            await makeCompactor(keepRecentShare: 0.05, outputReserve: 800).compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(1_000),
                measuring: .counted(
                    RequestMeasurement(tokenCount: 500, source: .reported),
                    by: { candidate in
                        measured.value = (measured.value ?? 0) + 1
                        return RequestMeasurement(tokenCount: candidate.entries.count * 20, source: .reported)
                    }),
                summarize: { _ in "rolled" }, trigger: .threshold))
        #expect((measured.value ?? 0) > 0)
    }

    @Test("an overrun after summarizing keeps the context on a threshold decision")
    func thresholdOverrunKeepsContextUnchanged() async throws {
        let (history, _) = try fiveTurns()
        let ctx = try context(history)
        let decision = try await makeCompactor(keepRecentShare: 0.05).compact(
            context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(1_000),
            measuring: .counted(
                RequestMeasurement(tokenCount: 500, source: .reported),
                by: { candidate in
                    let withSummary = candidate.entries.contains { text(in: $0).contains("rolled") }
                    return RequestMeasurement(tokenCount: withSummary ? 900 : 300, source: .reported)
                }),
            summarize: { _ in "rolled" }, trigger: .threshold)
        #expect(decision == .unchanged)
    }

    @Test("an overrun after summarizing a recovery propagates the overflow")
    func recoveryOverrunPropagates() async throws {
        let (history, _) = try fiveTurns()
        let ctx = try context(history)
        await #expect(throws: AgentRuntimeError.contextLengthExceeded) {
            _ = try await makeCompactor(keepRecentShare: 0.05).compact(
                context: ctx, request: assembleStandardPrompt(ctx), budget: try budget(1_000),
                measuring: .counted(
                    RequestMeasurement(tokenCount: 1_100, source: .reported),
                    by: { candidate in
                        let withSummary = candidate.entries.contains { text(in: $0).contains("rolled") }
                        return RequestMeasurement(tokenCount: withSummary ? 900 : 300, source: .reported)
                    }),
                summarize: { _ in "rolled" }, trigger: .contextLengthExceeded)
        }
    }
}

/// A tiny sendable box to capture closure outputs from the summarize hook.
private final class Box<Value: Sendable>: Sendable {
    private let storage = Mutex<Value?>(nil)

    var value: Value? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private struct TestFailure: Error {}
