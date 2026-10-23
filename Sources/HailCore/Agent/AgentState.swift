import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The event-sourced state of an ``Agent``. Kept as a separate value type so
/// the state transition can be tested and replayed without a distributed actor.
public struct AgentState: Codable, Sendable {
    /// State is the actor-local dashboard projection, not the history store.
    /// Keep its request timeline bounded; complete request history remains in
    /// the journal and is projected by `AgentJournalReader`.
    private static let maxRecentModelRequests = 100

    public var agentID: AgentID

    /// Who said what to the agent, and its work on each.
    public private(set) var history = AgentHistory()

    /// The most recent model requests, oldest first.
    public private(set) var modelRequests: [ModelRequestRecord] = []

    /// What the agent is doing, from what's open and running: a model request in flight, the open
    /// turn's last step, or how the last turn ended.
    public var runtimeState: AgentRuntimeState {
        if let request = modelRequests.last, case .running = request.outcome {
            if request.kind == .compaction { return .compacting }
            if case .called = history.open?.steps.last { return .executingTool }
            return .generating
        }
        if history.open != nil { return .generating }
        if case .failed = history.closed.last?.outcome { return .failed }
        return .idle
    }

    public private(set) var usageSummary: AgentUsageSummary = .init()

    /// The most recent context occupancy a provider reported.
    public private(set) var latestContextUsage: ContextUsage?

    public init(agentID: AgentID, history: AgentHistory = AgentHistory()) {
        self.agentID = agentID
        self.history = history
    }

    public mutating func apply(_ event: AgentEvent) throws(AgentHistory.InvalidEvent) {
        switch event {
        case .activated(let agentID):
            self.agentID = agentID
        case .history(let event):
            history = try history.applying(event)
        case .modelUsage(let usage, _):
            usageSummary.record(usage)
        case .contextUsage(let usage, _):
            latestContextUsage = usage
        case .modelRequestStarted(let record):
            modelRequests.append(record)
            if modelRequests.count > Self.maxRecentModelRequests {
                modelRequests.removeFirst(modelRequests.count - Self.maxRecentModelRequests)
            }
        case .modelRequestCompleted(let id, let usage, let durationMilliseconds, let at):
            if let index = modelRequests.lastIndex(where: { $0.id == id }) {
                modelRequests[index].completedAt = at
                modelRequests[index].durationMilliseconds = durationMilliseconds
                modelRequests[index].usage = usage
                modelRequests[index].outcome = .completed
            }
        case .modelRequestFailed(let id, let error, let durationMilliseconds, let at):
            if let index = modelRequests.lastIndex(where: { $0.id == id }) {
                modelRequests[index].completedAt = at
                modelRequests[index].durationMilliseconds = durationMilliseconds
                modelRequests[index].outcome = .failed(error)
            }
        case .deactivated:
            break
        }
    }

    /// A journal can end between any two events. Requests still running are marked interrupted.
    /// A turn still open is the one a crash interrupted: it stays open, for the agent to resume or
    /// close (``AgentHistory/open``).
    public mutating func normalizeAfterReplay() {
        for index in modelRequests.indices {
            if case .running = modelRequests[index].outcome {
                modelRequests[index].outcome = .interrupted
            }
        }
    }

    /// Value-oriented reducer form used by projections and tests.
    public func applying(_ event: AgentEvent) throws(AgentHistory.InvalidEvent) -> AgentState {
        var next = self
        try next.apply(event)
        return next
    }
}
