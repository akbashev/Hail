import AnyLanguageModel
import Foundation
import HTTPTypes

/// The requests to one provider account in flight at once: at most its limit, the rest waiting
/// here rather than at the provider, so a response-start timeout counts from when a request is
/// sent. Waiting requests go in order of their task's priority, then of arrival; a cancelled one
/// leaves the line. Its limit can change while it's in use.
public actor RequestPool {
    private struct Waiter {
        let id: UUID
        let priority: TaskPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// The most requests in flight at once.
    public private(set) var limit: Int
    private var inFlight = 0
    private var waiters: [Waiter] = []

    /// A pool of `limit` requests at once, one at least.
    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Changes the limit: a higher one lets waiting requests go now; a lower one holds new ones
    /// until enough in flight end.
    public func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        admitWaiting()
    }

    /// Runs `operation` holding a slot, which is given back however it ends.
    nonisolated func withSlot<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard inFlight >= limit else {
            inFlight += 1
            return
        }
        let id = UUID()
        let priority = Task.currentPriority
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Higher priority first; among the same priority, in order of arrival.
                let index = waiters.firstIndex { $0.priority < priority } ?? waiters.endIndex
                waiters.insert(Waiter(id: id, priority: priority, continuation: continuation), at: index)
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    func release() {
        inFlight -= 1
        admitWaiting()
    }

    private func admitWaiting() {
        while inFlight < limit, !waiters.isEmpty {
            inFlight += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func leave(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// A provider account, as its requests are limited: the account its key or server is.
public struct ModelAccount: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The request limits of provider accounts, and the transports their models send requests with.
///
/// A model's transport asks for its account's pool on every request, so a limit set while the
/// model is in use applies to its next request. An account with no limit sends right away.
public actor ModelTransports {
    private var pools: [ModelAccount: RequestPool] = [:]

    public init(limits: [ModelAccount: Int] = [:]) {
        for (account, limit) in limits { pools[account] = RequestPool(limit: limit) }
    }

    /// The limits set, by account.
    public var limits: [ModelAccount: Int] {
        get async {
            var limits: [ModelAccount: Int] = [:]
            for (account, pool) in pools { limits[account] = await pool.limit }
            return limits
        }
    }

    /// Sets `account`'s limit; `nil` sends its requests right away.
    public func setLimit(_ limit: Int?, for account: ModelAccount) async {
        guard let limit else {
            pools[account] = nil
            return
        }
        if let pool = pools[account] {
            await pool.setLimit(limit)
        } else {
            pools[account] = RequestPool(limit: limit)
        }
    }

    func pool(for account: ModelAccount) -> RequestPool? {
        pools[account]
    }

    /// How a model of `account` sends its requests: through `base`, in its account's pool.
    public nonisolated func transport(
        for account: ModelAccount,
        over base: any HTTPTransport = makeDefaultSession()
    ) -> any HTTPTransport {
        AccountTransport(account: account, transports: self, base: base)
    }
}

/// A model's transport: each request waits for a slot of its account's pool, if it has one.
private struct AccountTransport: HTTPTransport {
    let account: ModelAccount
    let transports: ModelTransports
    let base: any HTTPTransport

    @concurrent func perform<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration,
        // As AnyLanguageModel declares it, compiled without nonisolated(nonsending) by default.
        responseHandler: @concurrent (HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        guard let pool = await transports.pool(for: account) else {
            return try await base.perform(request: request, body: body, timeout: timeout, responseHandler: responseHandler)
        }
        return try await pool.withSlot {
            try await base.perform(request: request, body: body, timeout: timeout, responseHandler: responseHandler)
        }
    }
}
