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

        await #expect(throws: AgentRuntimeError.persistenceFailure("journal unavailable")) {
            _ = try await runner.run(
                model: "test/model",
                kind: .generation,
                stream: stream
            ) { _ in }
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
            _ = try await runner.run(
                model: "test/model",
                kind: .generation,
                stream: stream
            ) { (event: ModelEvent<String>) async throws(AgentRuntimeError) in
                if case .failed = event {
                    throw AgentRuntimeError.rateLimit
                }
            }
            Issue.record("Expected persistence failure")
        } catch let error as AgentRuntimeError {
            guard case .persistenceFailure(let message) = error else {
                Issue.record("Expected persistence failure, got \(error)")
                return
            }
            #expect(message.contains("Original failure"))
        } catch {
            Issue.record("Expected AgentRuntimeError, got \(error)")
        }
    }
}
