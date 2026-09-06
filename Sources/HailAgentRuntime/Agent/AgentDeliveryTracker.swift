import Foundation

/// Identifies an asynchronous agent-to-agent delivery attempt.
///
/// Delivery IDs are process-local observability handles. They are deliberately
/// not journaled: a process restart may lose a queued delivery, which is part
/// of the best-effort delivery contract.
public struct AgentDeliveryID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

public enum AgentDeliveryStatus: Sendable, Equatable {
    case queued
    case completed
    case failed(String)
}

/// Tracks fire-and-forget deliveries for the lifetime of the current process.
///
/// This actor provides ownership and observability for delivery tasks without
/// turning them into durable messages. A future durable outbox can implement
/// the same submission boundary without changing ``AgentTool``'s semantics.
public actor AgentDeliveryTracker {
    private static let retainedFinishedDeliveryLimit = 256

    private var tasks: [AgentDeliveryID: Task<Void, Never>] = [:]
    private var statuses: [AgentDeliveryID: AgentDeliveryStatus] = [:]
    private var finishedDeliveries: [AgentDeliveryID] = []

    public init() {}

    /// Enqueues an asynchronous operation and returns immediately after the
    /// operation has been accepted by this process.
    public func enqueue(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> AgentDeliveryID {
        let id = AgentDeliveryID()
        statuses[id] = .queued

        let task = Task { [weak self] in
            do {
                try await operation()
                await self?.finish(id, status: .completed)
            } catch {
                await self?.finish(id, status: .failed(String(describing: error)))
            }
        }
        tasks[id] = task
        return id
    }

    public func status(for id: AgentDeliveryID) -> AgentDeliveryStatus? {
        statuses[id]
    }

    public func activeDeliveryCount() -> Int {
        tasks.count
    }

    /// Cancels process-local work during runtime shutdown. It intentionally
    /// does not claim that the deliveries failed durably; no durable delivery
    /// guarantee exists yet.
    public func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    private func finish(_ id: AgentDeliveryID, status: AgentDeliveryStatus) {
        tasks.removeValue(forKey: id)
        statuses[id] = status
        finishedDeliveries.append(id)

        let excess = finishedDeliveries.count - Self.retainedFinishedDeliveryLimit
        guard excess > 0 else { return }
        for oldID in finishedDeliveries.prefix(excess) {
            statuses.removeValue(forKey: oldID)
        }
        finishedDeliveries.removeFirst(excess)
    }
}
