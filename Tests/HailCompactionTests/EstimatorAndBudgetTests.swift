import AnyLanguageModel
import HailAgentRuntime
import HailCore
import Testing

@testable import HailCompaction

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("TokenEstimator")
struct TokenEstimatorTests {
    private let estimator = TokenEstimator()

    private func text(_ content: String) -> ChatMessage {
        .text(sender: "user", content: content, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func prompt(_ content: String) -> Transcript.Entry {
        .prompt(.init(segments: [.text(.init(content: content))]))
    }

    @Test("a text message costs its characters plus framing overhead")
    func textEstimate() {
        // 40 characters at 4 chars/token = 10 tokens + 4 overhead.
        #expect(estimator.estimate(text(String(repeating: "a", count: 40))) == 14)
    }

    @Test("an empty thread estimates to zero")
    func emptyThread() {
        #expect(estimator.estimate([]) == 0)
    }

    @Test("tool calls count name and arguments")
    func toolCallEstimate() {
        let call = ToolCall(
            id: "1",
            name: "read_file",
            arguments: GeneratedContent(properties: ["path": "/tmp/x"])
        )
        let message = ChatMessage.toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 0))
        let expected = 4 + Int((Double(9 + "{\"path\":\"/tmp/x\"}".count) / 4.0).rounded(.up))
        #expect(estimator.estimate(message) == expected)
    }

    @Test("request estimation includes serialized tool schemas")
    func requestIncludesTools() async throws {
        let message = prompt("hello")
        let tool = TestToolDefinition.empty(
            name: "search",
            description: "Search the indexed workspace"
        )

        let withoutTools = try await estimator.estimate(messages: [message], tools: [])
        let withTools = try await estimator.estimate(messages: [message], tools: [tool])
        #expect(withTools > withoutTools)
    }

    @Test("a model-specific tokenizer can replace the heuristic")
    func exactTokenizerHook() async throws {
        let estimator = TokenEstimator(exactCount: { messages, tools in
            messages.count * 100 + tools.count * 10
        })
        let count = try await estimator.estimate(
            messages: [prompt("tiny")],
            tools: []
        )
        #expect(count == 100)
    }

    @Test("a configured tokenizer failure propagates")
    func exactTokenizerFailurePropagates() async {
        let estimator = TokenEstimator(exactCount: {
            (_: [Transcript.Entry], _: [ToolDefinition]) async throws(AgentRuntimeError) -> Int in
            throw AgentRuntimeError.infrastructureFailure("tokenizer unavailable")
        })

        await #expect(throws: AgentRuntimeError.infrastructureFailure("tokenizer unavailable")) {
            try await estimator.estimate(
                messages: [prompt("tiny")],
                tools: []
            )
        }
    }
}

@Suite("CompactionBudget")
struct CompactionBudgetTests {
    @Test("requires a positive context window")
    func positiveWindow() throws {
        #expect(try CompactionBudget(contextWindow: 131_072).contextWindow == 131_072)
        #expect(throws: AgentRuntimeError.self) {
            try CompactionBudget(contextWindow: 0)
        }
    }
}
