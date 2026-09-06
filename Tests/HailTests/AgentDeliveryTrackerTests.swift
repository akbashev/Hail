import Hail
import Testing

@testable import HailAgentRuntime

@Suite("Agent delivery tracking")
struct AgentDeliveryTrackerTests {
    @Test("accepted delivery is tracked until it completes")
    func tracksQueuedAndCompletedDelivery() async throws {
        let tracker = AgentDeliveryTracker()
        let gate = AsyncStream<Void>.makeStream()

        let id = await tracker.enqueue {
            for await _ in gate.stream {
                break
            }
        }

        #expect(await tracker.status(for: id) == .queued)
        #expect(await tracker.activeDeliveryCount() == 1)

        gate.continuation.yield(())
        gate.continuation.finish()

        try await eventually {
            await tracker.status(for: id) == .completed
        }
        #expect(await tracker.activeDeliveryCount() == 0)
    }

    @Test("failed delivery remains observable as failed")
    func tracksFailedDelivery() async throws {
        let tracker = AgentDeliveryTracker()

        let id = await tracker.enqueue {
            throw TestDeliveryError.failed
        }

        try await eventually {
            if case .failed = await tracker.status(for: id) {
                return true
            }
            return false
        }
        #expect(await tracker.activeDeliveryCount() == 0)
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition did not become true")
    }

    private enum TestDeliveryError: Error {
        case failed
    }
}
