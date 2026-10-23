import HailCore
import Synchronization

/// `CheckedContinuation` is not `Sendable`, so it cannot live in the race
/// state directly. The race resumes it exactly once (guarded by the
/// completion flag) from exactly one of three paths, so carrying it across
/// those paths is safe; the box only states that to the compiler.
private struct ResumeBox<T>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, any Error>?
}

/// One-shot race state shared by `withTimeout`'s operation task, its timeout
/// task, and the caller-cancellation handler. Exactly one path wins and its
/// outcome is delivered; every terminal path cancels the surviving tasks, so
/// neither the timeout sleep nor the operation outlives the call.
private final class TimeoutRace<T: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation = ResumeBox<T>()
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        /// The winning path's outcome. Recorded even when no continuation is
        /// registered yet — a fast operation can finish before `register`
        /// runs, and its result must not be dropped: `register` drains it.
        var terminal: Result<T, any Error>?
    }

    private let storage = Mutex(State())

    /// Hands the race its participants. Any path can win before the tasks are
    /// registered (the cancellation handler fires as soon as the caller is
    /// cancelled; a fast operation can finish during its own launch); the
    /// recorded terminal outcome is then delivered here, or the continuation
    /// would never be resumed at all.
    func register(
        continuation: CheckedContinuation<T, any Error>,
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        let terminal = storage.withLock { state -> Result<T, any Error>? in
            state.continuation.continuation = continuation
            state.operationTask = operationTask
            state.timeoutTask = timeoutTask
            return state.terminal
        }
        if let terminal {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.resume(with: terminal)
        }
    }

    /// The operation finished (successfully or not): deliver its outcome and
    /// cancel the timeout sleep, which previously ran on to completion. With
    /// no continuation registered yet the outcome is recorded for `register`.
    func finish(with result: Result<T, any Error>) {
        let (continuation, timeoutTask) = storage.withLock { state in
            guard state.terminal == nil else { return (ResumeBox<T>(), nil as Task<Void, Never>?) }
            state.terminal = result
            defer { state.continuation = ResumeBox<T>() }
            return (state.continuation, state.timeoutTask)
        }
        timeoutTask?.cancel()
        guard let continuation = continuation.continuation else { return }
        continuation.resume(with: result)
    }

    /// The timeout expired: cancel the operation and fail with `TimeoutError`.
    func timeout() {
        let operationTask = storage.withLock { $0.operationTask }
        operationTask?.cancel()
        finish(with: .failure(TimeoutError()))
    }

    /// The caller was cancelled: cancel both tasks and propagate. Without
    /// this the continuation had no cancellation path at all — a cancelled
    /// caller kept waiting for the operation or the timeout.
    func cancel() {
        let (operationTask, timeoutTask) = storage.withLock { ($0.operationTask, $0.timeoutTask) }
        operationTask?.cancel()
        timeoutTask?.cancel()
        finish(with: .failure(CancellationError()))
    }
}

/// Runs `operation` with a timeout. If the timeout expires before the
/// operation completes, the task is cancelled and `TimeoutError` is thrown.
/// Cancelling the caller cancels the operation and throws `CancellationError`.
///
/// Unlike `withThrowingTaskGroup`, this implementation does **not** wait for
/// the operation task to finish after a timeout. That matters when the
/// operation is stuck in synchronous code that ignores cancellation (e.g.
/// a blocking `Process` call).
/// In those cases `withThrowingTaskGroup` would keep the timeout from
/// surfacing because the group waits for all child tasks to complete.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task {
                do {
                    let result = try await operation()
                    race.finish(with: .success(result))
                } catch {
                    race.finish(with: .failure(error))
                }
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    race.timeout()
                } catch {
                    // Timeout task cancelled: the operation finished first or
                    // the caller was cancelled.
                }
            }
            race.register(
                continuation: continuation,
                operationTask: operationTask,
                timeoutTask: timeoutTask
            )
        }
    } onCancel: {
        race.cancel()
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
