import Foundation
import Synchronization
import Testing

@testable import HailModelRuntime

@Suite("Request pool")
struct RequestPoolTests {
    @Test func aRequestPastTheLimitWaitsForASlot() async throws {
        let pool = RequestPool(limit: 1)
        let order = Mutex<[String]>([])
        try await pool.acquire()
        let second = Task { try await pool.withSlot { order.withLock { $0.append("second") } } }
        try await Task.sleep(for: .milliseconds(50))
        order.withLock { $0.append("first done") }
        await pool.release()
        try await second.value
        #expect(order.withLock { $0 } == ["first done", "second"])
    }

    @Test func waitingRequestsGoInOrderOfPriority() async throws {
        let pool = RequestPool(limit: 1)
        let order = Mutex<[String]>([])
        try await pool.acquire()
        let background = Task(priority: .background) {
            try await pool.withSlot { order.withLock { $0.append("background") } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let userInitiated = Task(priority: .userInitiated) {
            try await pool.withSlot { order.withLock { $0.append("userInitiated") } }
        }
        try await Task.sleep(for: .milliseconds(50))
        await pool.release()
        try await background.value
        try await userInitiated.value
        #expect(order.withLock { $0 } == ["userInitiated", "background"])
    }

    @Test func aCancelledRequestLeavesTheLine() async throws {
        let pool = RequestPool(limit: 1)
        try await pool.acquire()
        let cancelled = Task { try await pool.withSlot { "ran" } }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await pool.release()
        #expect(try await pool.withSlot { "next" } == "next")
    }

    @Test func raisingTheLimitLetsWaitingRequestsGo() async throws {
        let pool = RequestPool(limit: 1)
        try await pool.acquire()
        let waiting = Task { try await pool.withSlot { "sent" } }
        try await Task.sleep(for: .milliseconds(50))
        await pool.setLimit(2)
        #expect(try await waiting.value == "sent")
    }

    @Test func anAccountWithoutALimitSendsRightAway() async throws {
        let transports = ModelTransports(limits: [ModelAccount(rawValue: "ollama-cloud"): 1])
        #expect(await transports.pool(for: ModelAccount(rawValue: "anthropic")) == nil)
        #expect(await transports.pool(for: ModelAccount(rawValue: "ollama-cloud")) != nil)
        await transports.setLimit(nil, for: ModelAccount(rawValue: "ollama-cloud"))
        #expect(await transports.pool(for: ModelAccount(rawValue: "ollama-cloud")) == nil)
    }
}
