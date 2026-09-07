import HailAgentRuntime
import HailCore
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
    private let taskInstructions = PromptAssemblyInstructions(
        task: """
            Rules:
            1. Work ONLY on the task described in the user message.
            2. Do not write to files outside the workspace.
            3. Use the available tools to complete the task.
            """
    )

    // MARK: Helpers

    private func text(_ content: String, _ offset: TimeInterval) -> ChatMessage {
        .text(sender: "user", content: content, timestamp: Date(timeIntervalSince1970: offset))
    }

    private func context(
        thread: [ChatMessage],
        summary: String? = nil,
        memory: [String] = []
    ) throws -> PromptContext {
        PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModelReference("test/fake")
                ),
                limits: .init()
            ),
            workingMemory: memory,
            contextSummary: summary,
            conversationThread: thread,
            contextManifest: ContextManifest(items: []),
            instructions: taskInstructions
        )
    }

    private func preparedRequest(for context: PromptContext) -> PreparedRequest {
        assembleStandardPrompt(context)
    }

    private func requireCompaction(
        _ decision: CompactionDecision,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ConversationCompaction {
        guard case .compacted(let compaction) = decision else {
            Issue.record("Expected a compaction decision", sourceLocation: sourceLocation)
            throw TestFailure()
        }
        return compaction
    }

    /// A compactor with a request-sized 1,000-token window. The fixture uses a
    /// 10% soft threshold and reserves 850 tokens, leaving a 150-token target
    /// for the assembled prompt so suffix selection is exercised.
    private func makeCompactor(
        keepRecent: Int = 2,
        outputReserve: Int = 850
    ) -> SlidingWindowCompactor {
        SlidingWindowCompactor(
            threshold: 0.1,
            keepRecent: keepRecent,
            outputReserve: outputReserve,
            toolResultReserve: 0
        )
    }

    private func budget() throws -> CompactionBudget {
        try CompactionBudget(contextWindow: 1_000)
    }

    // MARK: Tests

    @Test("a context under the threshold compacts nothing")
    func underThresholdNoCompaction() async throws {
        let compactor = makeCompactor()
        // Two short messages: far below 70 tokens.
        let ctx = try context(thread: [text("hi", 0), text("hello", 1)])

        let result = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { _ in "unused" }
        #expect(result == .unchanged)
    }

    @Test("over threshold, the oldest messages are archived and the tail kept")
    func compactionArchivesPrefix() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        // 5 messages of 40 chars each ≈ 5 × 14 = 70 tokens → triggers.
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        #expect(result.summary == "rolled")
        // The preferred tail is kept when it fits; the exact cut follows the
        // serialized request estimate, including prompt framing.
        #expect(result.archivedCount == 2)
    }

    @Test("an oversized archived message is chunked for summarization")
    func oversizedArchivedMessageIsChunked() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        let thread = [
            text(String(repeating: "a", count: 12_000), 0),
            text("recent one", 1),
            text("recent two", 2),
        ]
        let calls = Box<Int>()
        calls.value = 0

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in
                calls.value = (calls.value ?? 0) + 1
                return "rolled"
            }
        )

        #expect(result.archivedCount == 1)
        #expect(calls.value ?? 0 > 1)
    }

    @Test("the existing rolling summary is folded into the summarize prompt")
    func priorSummaryFoldedIn() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let box = Box<[LLMMessage]>()

        let ctx = try context(thread: thread, summary: "v1")
        _ = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { messages in
            box.value = messages
            return "v2"
        }

        let prompt = try #require(box.value)
        #expect(prompt.count == 2)
        #expect(prompt[0].role == .system)
        #expect(prompt[1].content.contains("Summary so far: v1"))
    }

    @Test("the cut never splits a tool call from its result")
    func toolPairIntegrity() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        // Thread over threshold where the naive cut lands right after a
        // toolCall — its result would be orphaned in the kept suffix.
        let call = ToolCall(id: "1", name: "read_file", arguments: ToolArguments(json: "{}"))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 40), 0),
            text(String(repeating: "b", count: 40), 1),
            text(String(repeating: "c", count: 40), 2),
            .toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 3)),
            .toolResult(id: "1", content: "contents", timestamp: Date(timeIntervalSince1970: 4)),
            text(String(repeating: "d", count: 40), 5),
        ]

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The cut backs off before the trailing toolCall, so its result stays
        // together with the call in the retained suffix.
        #expect(result.archivedCount == 3)
    }

    @Test("the cut keeps every result of a parallel tool call with its call")
    func parallelToolResultsStayTogether() async throws {
        let compactor = makeCompactor(keepRecent: 2, outputReserve: 800)
        let first = ToolCall(id: "1", name: "read_file", arguments: ToolArguments(json: "{}"))
        let second = ToolCall(id: "2", name: "read_file", arguments: ToolArguments(json: "{}"))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 80), 0),
            text(String(repeating: "b", count: 80), 1),
            .toolCall(calls: [first, second], timestamp: Date(timeIntervalSince1970: 2)),
            .toolResult(id: "1", content: "first", timestamp: Date(timeIntervalSince1970: 3)),
            .toolResult(id: "2", content: "second", timestamp: Date(timeIntervalSince1970: 4)),
            text(String(repeating: "c", count: 80), 5),
        ]

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The naive cut is after the first result. Both results must remain
        // with the shared tool-call message, so the cut moves before it.
        #expect(result.archivedCount == 2)
    }

    @Test("the message opening the in-flight turn is never archived")
    func lastMessageNeverArchived() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )
        // The newest message is protected, while the budget determines how
        // much additional recent history can remain.
        #expect(result.archivedCount == 3)
    }

    @Test("nothing to archive when the whole thread fits the kept tail")
    func nothingToArchive() async throws {
        // Huge estimator weight via working memory, tiny thread.
        let compactor = makeCompactor(keepRecent: 10)
        let thread = [text("hi", 0), text("hello", 1)]
        let memory = [String(repeating: "m", count: 400)]  // 100 tokens → triggers

        let ctx = try context(thread: thread, memory: memory)
        let result = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { _ in
            "unused"
        }
        #expect(result == .unchanged)
    }

    @Test("endpoint token counter is used for candidate fitting")
    func endpointCounterFitsCandidates() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 800)
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        var ctx = try context(thread: thread)
        ctx = ctx.withMeasurement(
            PromptMeasurement(
                projectedTokenCount: 500,
                tokenCounting: .available { messages, _ in
                    // Deliberately disagree with the character estimator: the exact
                    // tokenizer says each rendered message costs 40 tokens.
                    messages.count * 40
                }))

        let request = assembleStandardPrompt(ctx)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The task prompt has two stable system messages. With a 200-token
        // retained target, the exact counter archives the first two thread
        // messages; the fallback estimator would choose a different cut.
        #expect(result.archivedCount == 2)
    }

    @Test("assistant narration stays attached to the following tool group")
    func assistantNarrationToolGroupIntegrity() async throws {
        let compactor = makeCompactor(keepRecent: 2, outputReserve: 760)
        let call = ToolCall(id: "1", name: "read_file", arguments: ToolArguments(json: "{}"))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 40), 0),
            .text(sender: agentID.rawValue, content: "I will inspect it.", timestamp: Date(timeIntervalSince1970: 1)),
            .toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 2)),
            .toolResult(id: "1", content: "contents", timestamp: Date(timeIntervalSince1970: 3)),
            text(String(repeating: "b", count: 40), 4),
            text(String(repeating: "c", count: 40), 5),
        ]
        var ctx = try context(thread: thread)
        ctx = ctx.withMeasurement(
            PromptMeasurement(
                projectedTokenCount: 500,
                tokenCounting: .available { messages, _ in messages.count * 40 }
            ))

        let request = assembleStandardPrompt(ctx)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget()
            ) { _ in "rolled" }
        )

        // A cut after the narration would orphan the tool call. The next
        // valid boundary is after the complete narration/call/result group.
        #expect(result.archivedCount == 4)
    }

    @Test("reused tool IDs do not merge separate interactions")
    func repeatedToolIDsStaySeparate() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 400)
        let call1 = ToolCall(id: "repeat", name: "read_file", arguments: ToolArguments(json: "{}"))
        let call2 = ToolCall(id: "repeat", name: "read_file", arguments: ToolArguments(json: "{}"))
        let thread: [ChatMessage] = [
            text("old", 0),
            .toolCall(calls: [call1], timestamp: Date(timeIntervalSince1970: 1)),
            .toolResult(id: "repeat", content: "first", timestamp: Date(timeIntervalSince1970: 2)),
            text("between", 3),
            .toolCall(calls: [call2], timestamp: Date(timeIntervalSince1970: 4)),
            .toolResult(id: "repeat", content: "second", timestamp: Date(timeIntervalSince1970: 5)),
            text("tail", 6),
        ]
        var ctx = try context(thread: thread)
        ctx = ctx.withMeasurement(
            PromptMeasurement(
                projectedTokenCount: 900,
                tokenCounting: .available { messages, _ in messages.count * 100 }
            ))
        let request = assembleStandardPrompt(ctx)

        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The first call/result pair is archivable independently. A global
        // ID-based range would incorrectly merge both rounds and force the
        // cut all the way past the second result.
        #expect(result.archivedCount == 3)
    }
}

/// A tiny sendable box to capture closure outputs from the summarize hook.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

private struct TestFailure: Error {}
