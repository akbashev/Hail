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
            arguments: ToolArguments(json: "{\"path\":\"/tmp/x\"}")
        )
        let message = ChatMessage.toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 0))
        let expected = 4 + Int((Double(9 + "{\"path\":\"/tmp/x\"}".count) / 4.0).rounded(.up))
        #expect(estimator.estimate(message) == expected)
    }

    @Test("request estimation includes serialized tool schemas")
    func requestIncludesTools() async throws {
        let message = LLMMessage(role: .user, content: "hello")
        let tool = LLMToolSchema(
            type: "function",
            function: .init(
                name: "search",
                description: "Search the indexed workspace",
                parameters: .init(type: "object", properties: nil, required: nil)
            )
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
            messages: [LLMMessage(role: .user, content: "tiny")],
            tools: []
        )
        #expect(count == 100)
    }

    @Test("a configured tokenizer failure propagates")
    func exactTokenizerFailurePropagates() async {
        struct TokenizerError: Error {}
        let estimator = TokenEstimator(exactCount: { _, _ in throw TokenizerError() })

        await #expect(throws: TokenizerError.self) {
            try await estimator.estimate(
                messages: [LLMMessage(role: .user, content: "tiny")],
                tools: []
            )
        }
    }
}

@Suite("ContextWindowBudget")
struct ContextWindowBudgetTests {
    @Test("unknown models get the conservative default (Ollama num_ctx)")
    func unknownModelDefaults() {
        #expect(ContextWindowBudget().budget(for: "llama3.2") == 4096)
    }

    @Test("unknown models use the conservative default")
    func unknownHostedModelDefaults() {
        #expect(ContextWindowBudget().budget(for: "claude-sonnet-4") == 4096)
    }

    @Test("host overrides win over the default")
    func overrideWins() {
        let budget = ContextWindowBudget(overrides: [("llama3.2", 131_072)])
        #expect(budget.budget(for: "llama3.2") == 131_072)
    }
}
