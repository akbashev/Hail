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

    // MARK: Helpers

    private func text(_ content: String, _ offset: TimeInterval) -> ChatMessage {
        .text(sender: "user", content: content, timestamp: Date(timeIntervalSince1970: offset))
    }

    private func context(
        thread: [ChatMessage],
        summary: String? = nil,
        memory: [String] = []
    ) -> PromptContext {
        PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(systemPrompt: "sys", model: "fake"),
                limits: .init()
            ),
            projectRootPath: "/tmp",
            workingMemory: memory,
            contextSummary: summary,
            conversationThread: thread,
            contextManifest: ContextManifest(items: [])
        )
    }

    /// A compactor with a 100-token window triggering at 70 tokens.
    private func makeCompactor(keepRecent: Int = 2) -> SlidingWindowCompactor {
        SlidingWindowCompactor(
            budget: ContextWindowBudget(overrides: [("fake", 100)]),
            keepRecent: keepRecent
        )
    }

    // MARK: Tests

    @Test("a context under the threshold compacts nothing")
    func underThresholdNoCompaction() async throws {
        let compactor = makeCompactor()
        // Two short messages: far below 70 tokens.
        let ctx = context(thread: [text("hi", 0), text("hello", 1)])

        let result = try await compactor.compact(context: ctx) { _ in "unused" }
        #expect(result == nil)
    }

    @Test("over threshold, the oldest messages are archived and the tail kept")
    func compactionArchivesPrefix() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        // 5 messages of 40 chars each ≈ 5 × 14 = 70 tokens → triggers.
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let result = try await compactor.compact(context: context(thread: thread)) { _ in "rolled" }

        #expect(result?.summary == "rolled")
        // The newest 2 stay verbatim.
        #expect(result?.archivedCount == 3)
    }

    @Test("the existing rolling summary is folded into the summarize prompt")
    func priorSummaryFoldedIn() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let box = Box<[LLMMessage]>()

        _ = try await compactor.compact(context: context(thread: thread, summary: "v1")) { messages in
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

        let result = try #require(
            await compactor.compact(context: context(thread: thread)) { _ in "rolled" }
        )

        // Naive cut = 4 (archives through the toolCall, orphans the result);
        // backing off the trailing toolCall archives only the 3 texts. The
        // tool pair stays together in the kept suffix.
        #expect(result.archivedCount == 3)
    }

    @Test("the cut keeps every result of a parallel tool call with its call")
    func parallelToolResultsStayTogether() async throws {
        let compactor = makeCompactor(keepRecent: 2)
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

        let result = try #require(
            await compactor.compact(context: context(thread: thread)) { _ in "rolled" }
        )

        // The naive cut is after the first result. Both results must remain
        // with the shared tool-call message, so the cut moves before it.
        #expect(result.archivedCount == 2)
    }

    @Test("the message opening the in-flight turn is never archived")
    func lastMessageNeverArchived() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let result = try #require(
            await compactor.compact(context: context(thread: thread)) { _ in "rolled" }
        )
        // 6 messages, keep 1 → archive 5, last message survives.
        #expect(result.archivedCount == 5)
    }

    @Test("nothing to archive when the whole thread fits the kept tail")
    func nothingToArchive() async throws {
        // Huge estimator weight via working memory, tiny thread.
        let compactor = makeCompactor(keepRecent: 10)
        let thread = [text("hi", 0), text("hello", 1)]
        let memory = [String(repeating: "m", count: 400)]  // 100 tokens → triggers

        let result = try await compactor.compact(context: context(thread: thread, memory: memory)) { _ in
            "unused"
        }
        #expect(result == nil)
    }
}

/// A tiny sendable box to capture closure outputs from the summarize hook.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}
