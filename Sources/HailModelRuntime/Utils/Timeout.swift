import HailCore
import Synchronization

/// Runs `operation` with a timeout. If the timeout expires before the
/// operation completes, the task is cancelled and `TimeoutError` is thrown.
///
/// Unlike `withThrowingTaskGroup`, this implementation does **not** wait for
/// the operation task to finish after a timeout. That matters when the
/// operation is stuck in synchronous code that ignores cancellation (e.g.
/// `swift-acp`'s shell-environment loader or a blocking `Process` call).
/// In those cases `withThrowingTaskGroup` would keep the timeout from
/// surfacing because the group waits for all child tasks to complete.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let completed = Mutex(false)
    return try await withCheckedThrowingContinuation { continuation in
        let task = Task {
            do {
                let result = try await operation()
                completed.withLock { isCompleted in
                    if !isCompleted {
                        isCompleted = true
                        continuation.resume(returning: result)
                    }
                }
            } catch {
                completed.withLock { isCompleted in
                    if !isCompleted {
                        isCompleted = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                task.cancel()
                completed.withLock { isCompleted in
                    if !isCompleted {
                        isCompleted = true
                        continuation.resume(throwing: TimeoutError())
                    }
                }
            } catch {
                // Timeout task was cancelled because the operation finished first.
            }
        }
    }
}

public func withTimeout<T: Sendable>(
    seconds: Int,
    operation: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await withTimeout(seconds: Double(seconds), operation: body)
    } catch {
        if error is TimeoutError {
            throw TimeoutError(operation: operation)
        }
        throw error
    }
}

public struct TimeoutError: Error, Sendable {
    public let operation: String?

    public init(operation: String? = nil) {
        self.operation = operation
    }
}
