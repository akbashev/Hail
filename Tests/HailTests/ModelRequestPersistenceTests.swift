import HailCore
import Testing

@testable import HailAgentRuntime

@Suite("Model request persistence")
struct ModelRequestPersistenceTests {
    @Test("failure to journal a request start becomes a persistence failure")
    func failedStartWriteIsNotMisclassified() async {
        let runner = ReasoningLoop<ContinuousClock>.ModelRequestRunner(
            turnID: TurnID(),
            emit: { (_: AgentEvent) async throws(AgentRuntimeError) in
                throw AgentRuntimeError.persistenceFailure("journal unavailable")
            },
            recordActivity: { _ in },
            clock: ContinuousClock()
        )
        let stream = AsyncStream<ModelEvent<String>> { $0.finish() }

        do {
            try await runner.run(model: "test/model", kind: .generation, stream: stream, from: ()) { _, _ in }
            Issue.record("Expected persistence failure")
        } catch {
            #expect(error.error == .persistenceFailure("journal unavailable"))
        }
    }

    @Test("failure to journal a failed request becomes a persistence failure")
    func failedFailureWriteIsNotSuppressed() async {
        let runner = ReasoningLoop<ContinuousClock>.ModelRequestRunner(
            turnID: TurnID(),
            emit: { (event: AgentEvent) async throws(AgentRuntimeError) in
                if case .modelRequestFailed = event {
                    throw AgentRuntimeError.persistenceFailure("journal unavailable")
                }
            },
            recordActivity: { _ in },
            clock: ContinuousClock()
        )
        let stream = AsyncStream<ModelEvent<String>> { continuation in
            continuation.yield(.failed(.rateLimit))
            continuation.finish()
        }

        do {
            try await runner.run(model: "test/model", kind: .generation, stream: stream, from: ()) {
                (_: Void, event: ModelEvent<String>) async throws(AgentRuntimeError) in
                if case .failed = event {
                    throw AgentRuntimeError.rateLimit
                }
            }
            Issue.record("Expected persistence failure")
        } catch {
            guard case .persistenceFailure(let message) = error.error else {
                Issue.record("Expected persistence failure, got \(error.error)")
                return
            }
            #expect(message.contains("Original failure"))
        }
    }
}
