import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `withTimeout` contract: an operation that beats the ceiling returns
/// promptly, an operation stuck past the ceiling fails with `TimeoutError`,
/// and cancelling the caller fails promptly with `CancellationError`
/// (previously the continuation had no cancellation path and the caller kept
/// waiting for the operation or the ceiling).
@Suite("withTimeout")
struct TimeoutTests {
    @Test("operation that wins returns promptly without waiting out the timeout")
    func operationWinsPromptly() async throws {
        let start = Date()
        let value = try await withTimeout(seconds: 30) {
            42
        }
        #expect(value == 42)
        // Nowhere near the 30s ceiling.
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("operation stuck past the ceiling fails with TimeoutError")
    func timeoutThrows() async throws {
        let start = Date()
        await #expect {
            _ = try await withTimeout(seconds: 1) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        } throws: { error in
            error is TimeoutError
        }
        let elapsed = Date().timeIntervalSince(start)
        // Lower bound pins the failure to the ceiling; the upper bound shows
        // the stuck operation's own 30s sleep was not awaited.
        #expect(elapsed >= 1)
        #expect(elapsed < 10)
    }

    @Test("cancelling the caller fails promptly with CancellationError")
    func callerCancellationPropagates() async throws {
        let start = Date()
        let task = Task {
            try await withTimeout(seconds: 30) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect {
            _ = try await task.value
        } throws: { error in
            error is CancellationError
        }
        // Neither the operation's 30s sleep nor the 30s ceiling is awaited.
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// Regression: a fast operation could finish *before* the race registered
    /// the continuation — its result was dropped and the caller resumed with
    /// `CancellationError` instead of the value. Looped because the loss was
    /// scheduling-dependent, not deterministic.
    @Test("an already-completed operation returns its value, never CancellationError")
    func instantCompletionKeepsValue() async throws {
        for _ in 0..<1_000 {
            let value = try await withTimeout(seconds: 30) { 42 }
            #expect(value == 42)
        }
    }
}
