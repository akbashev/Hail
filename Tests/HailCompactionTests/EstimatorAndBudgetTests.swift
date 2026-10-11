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

    private func prompt(_ content: String) -> Transcript.Entry {
        .prompt(.init(segments: [.text(.init(content: content))]))
    }

    @Test("text costs its characters at four per token")
    func textEstimate() {
        #expect(estimator.estimate(String(repeating: "a", count: 40)) == 10)
    }

    @Test("an empty request estimates to zero")
    func emptyRequest() async throws {
        #expect(try await estimator.estimate(messages: [], tools: []) == 0)
    }

    @Test("a longer message costs more")
    func longerCostsMore() async throws {
        let short = try await estimator.estimate(messages: [prompt("hi")], tools: [])
        let long = try await estimator.estimate(messages: [prompt(String(repeating: "hello ", count: 50))], tools: [])
        #expect(long > short)
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
