import HailCore
import Testing

@testable import HailAgentRuntime

@Suite("Model request persistence")
struct ModelRequestPersistenceTests {
    private struct JournalError: Error {}

    @Test("failure to journal a failed request becomes a persistence failure")
    func failedFailureWriteIsNotSuppressed() async {
        let runner = ReasoningLoop<ContinuousClock>.ModelRequestRunner(
            turnID: TurnID(),
            emit: { event in
                if case .modelRequestFailed = event {
                    throw JournalError()
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
            ) { event in
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
