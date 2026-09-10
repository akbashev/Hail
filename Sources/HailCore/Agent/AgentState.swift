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
    /// the journal and is projected by `AgentHistoryReader`.
    private static let maxRecentModelRequests = 100

    public var agentID: AgentID
    public var conversationThread: [ChatMessage]

    /// The rolling summary of compacted-away conversation history. Each
    /// `conversationCompacted` event REPLACES it (the new summary folds the
    /// old one in), so the window carries at most one summary no matter how
    /// many compactions ran.
    public private(set) var contextSummary: String? = nil

    /// The turn currently in flight, if any. Set by `turnStarted`, cleared by
    /// `turnCompleted`. `opening` is the message that opened the turn (once
    /// journaled); `responded` records that a response made it to the journal.
    public private(set) var activeTurn: ActiveTurn?

    /// Recent durable model requests, including compaction requests. Complete
    /// journal history remains available to an external AgentHistoryReader;
    /// this state projection keeps dashboard reads local to the actor.
    public private(set) var modelRequests: [ModelRequestRecord] = []

    public private(set) var phase: AgentPhase = .idle
    public private(set) var currentToolName: String?

    /// The opening message of a turn interrupted by a crash, folded by
    /// ``normalizeAfterReplay()``. The agent re-runs it after activation (when
    /// configured to). It is NOT cleared by `turnStarted`: the re-run starts a
    /// fresh turn before re-journaling its opening, so the marker must survive
    /// until `messageReceived` can recognize — and collapse — the duplicate.
    /// A non-matching opening clears it as stale.
    public private(set) var pendingTurnRerun: ChatMessage?

    /// The harness session this agent's turns run in (kimi/claude CLI), if
    /// journaled. The id and identity are one invariant-bearing value so a
    /// state snapshot cannot contain only half of a resumable session.
    public private(set) var modelSession: ModelSessionResume?

    /// Durable token totals projected from ``AgentEvent/modelUsage``. Kept
    /// outside the conversation so prompt assembly and compaction never see
    /// accounting metadata.
    public private(set) var usageSummary: AgentUsageSummary = .init()

    /// The latest provider-reported context occupancy, if any.
    public private(set) var latestContextUsage: ContextUsage?

    /// A reasoning turn in progress.
    public struct ActiveTurn: Codable, Sendable, Equatable {
        public var opening: ChatMessage?
        public var responded: Bool
        public var id: TurnID?
        public var startedAt: Date?

        public init(
            opening: ChatMessage? = nil,
            responded: Bool = false,
            id: TurnID? = nil,
            startedAt: Date? = nil
        ) {
            self.opening = opening
            self.responded = responded
            self.id = id
            self.startedAt = startedAt
        }

        private enum CodingKeys: String, CodingKey {
            case opening, responded, id, startedAt
        }

        /// New turn metadata was added after journals already contained
        /// `activeTurn`. Decode the new fields optionally so an old snapshot
        /// with only `opening` and `responded` remains loadable.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            opening = try container.decodeIfPresent(ChatMessage.self, forKey: .opening)
            responded = try container.decodeIfPresent(Bool.self, forKey: .responded) ?? false
            id = try container.decodeIfPresent(TurnID.self, forKey: .id)
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(opening, forKey: .opening)
            try container.encode(responded, forKey: .responded)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(startedAt, forKey: .startedAt)
        }
    }

    public init(
        agentID: AgentID,
        conversationThread: [ChatMessage] = []
    ) {
        self.agentID = agentID
        self.conversationThread = conversationThread
    }

    private enum CodingKeys: String, CodingKey {
        case agentID, conversationThread, contextSummary, activeTurn,
            pendingTurnRerun, modelSession, usageSummary,
            latestContextUsage, modelRequests, phase, currentToolName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(AgentID.self, forKey: .agentID)
        conversationThread = try container.decode([ChatMessage].self, forKey: .conversationThread)
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        activeTurn = try container.decodeIfPresent(ActiveTurn.self, forKey: .activeTurn)
        pendingTurnRerun = try container.decodeIfPresent(ChatMessage.self, forKey: .pendingTurnRerun)
        modelSession = try container.decodeIfPresent(ModelSessionResume.self, forKey: .modelSession)
        usageSummary = try container.decodeIfPresent(AgentUsageSummary.self, forKey: .usageSummary) ?? .init()
        latestContextUsage = try container.decodeIfPresent(ContextUsage.self, forKey: .latestContextUsage)
        modelRequests = try container.decodeIfPresent([ModelRequestRecord].self, forKey: .modelRequests) ?? []
        if modelRequests.count > Self.maxRecentModelRequests {
            modelRequests.removeFirst(modelRequests.count - Self.maxRecentModelRequests)
        }
        phase = try container.decodeIfPresent(AgentPhase.self, forKey: .phase) ?? .idle
        currentToolName = try container.decodeIfPresent(String.self, forKey: .currentToolName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(conversationThread, forKey: .conversationThread)
        try container.encodeIfPresent(contextSummary, forKey: .contextSummary)
        try container.encodeIfPresent(activeTurn, forKey: .activeTurn)
        try container.encodeIfPresent(pendingTurnRerun, forKey: .pendingTurnRerun)
        try container.encodeIfPresent(modelSession, forKey: .modelSession)
        try container.encode(usageSummary, forKey: .usageSummary)
        try container.encodeIfPresent(latestContextUsage, forKey: .latestContextUsage)
        try container.encode(modelRequests, forKey: .modelRequests)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(currentToolName, forKey: .currentToolName)
    }

    /// Apply a single event to this state. This is the only place where event
    /// replay mutates agent state, making the transition deterministic and
    /// testable.
    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .activated(let agentID):
            self.agentID = agentID
        case .turnStarted(let at):
            // Deliberately keeps `pendingTurnRerun`: the crash-recovery re-run
            // starts a fresh turn before re-journaling its opening, so the
            // marker must survive until `messageReceived` recognizes it.
            activeTurn = ActiveTurn(startedAt: at)
            phase = .generating
            currentToolName = nil
        case .turnIdentified(let id):
            activeTurn?.id = id
        case .messageReceived(let message):
            // Crash-recovery fold: an interrupted turn is re-run after replay
            // and the loop re-journals the exact same opening message (same
            // timestamp), so the duplicate collapses against
            // `pendingTurnRerun`. This works even when the crash happened
            // after tool events, where the thread tail is a tool call or
            // result and the old `last != message` check alone would append
            // the opening a second time. Genuinely repeated messages carry
            // fresh timestamps and are kept; the `last != message` check
            // stays as a secondary guard.
            let isRerunOpening = message == pendingTurnRerun
            if !isRerunOpening, conversationThread.last != message {
                conversationThread.append(message)
            }
            switch message {
            case .decisionRequest, .decisionResolved:
                // Display-only posts (``Agent/post(_:)``) never open a turn, so
                // they must not become the re-run candidate after a crash —
                // nor clear a pending one.
                break
            default:
                if isRerunOpening {
                    // The collapsed duplicate still opens the re-run's turn,
                    // then the marker is consumed.
                    activeTurn?.opening = message
                    pendingTurnRerun = nil
                } else {
                    // A non-matching opening means the marker is stale (or
                    // none was pending); clear it so it cannot collapse a
                    // later unrelated message.
                    pendingTurnRerun = nil
                    if activeTurn?.opening == nil {
                        activeTurn?.opening = message
                    }
                }
            }
        case .assistantToolRound(let content, let thinking, let calls, let at):
            conversationThread.append(
                .assistantToolCall(
                    content: content,
                    thinking: thinking,
                    calls: calls,
                    timestamp: at
                )
            )
            phase = .executingTool
            currentToolName = calls.first?.name
        case .toolResult(let result, let at):
            conversationThread.append(
                .toolResult(
                    id: result.toolCallID,
                    content: result.output,
                    timestamp: replayTimestamp(for: at)
                )
            )
            phase = .generating
            currentToolName = nil
        case .conversationCompacted(let archivedCount, let summary):
            contextSummary = summary
            if archivedCount > 0 && archivedCount <= conversationThread.count {
                conversationThread.removeFirst(archivedCount)
            }
            phase = .generating
        case .responseReceived(let sender, let payload, let timestamp):
            conversationThread.append(.response(sender: sender, payload: payload, timestamp: timestamp))
            activeTurn?.responded = true
        case .turnFailed(let error, let at):
            conversationThread.append(.failure(error: error, timestamp: at))
            phase = .failed
            currentToolName = nil
        case .turnCompleted:
            activeTurn = nil
            phase = .idle
            currentToolName = nil
        case .modelUsage(let usage, _):
            usageSummary.record(usage)
        case .contextUsage(let usage, _):
            latestContextUsage = usage
        case .modelRequestStarted(let record):
            modelRequests.append(record)
            if modelRequests.count > Self.maxRecentModelRequests {
                modelRequests.removeFirst(modelRequests.count - Self.maxRecentModelRequests)
            }
            phase = record.kind == .compaction ? .compacting : .generating
        case .modelRequestCompleted(let id, let usage, let durationMilliseconds, let at):
            if let index = modelRequests.lastIndex(where: { $0.id == id }) {
                modelRequests[index].completedAt = at
                modelRequests[index].durationMilliseconds = durationMilliseconds
                modelRequests[index].usage = usage
                modelRequests[index].outcome = .completed
                if activeTurn != nil {
                    phase = .generating
                }
            }
        case .modelRequestFailed(let id, let error, let durationMilliseconds, let at):
            if let index = modelRequests.lastIndex(where: { $0.id == id }) {
                modelRequests[index].completedAt = at
                modelRequests[index].durationMilliseconds = durationMilliseconds
                modelRequests[index].outcome = .failed(error)
                if activeTurn != nil {
                    phase = .generating
                }
            }
        case .modelSessionIdentified(let id, let identity):
            modelSession = ModelSessionResume(id: id, identity: identity)
        case .deactivated:
            break
        }
    }

    /// After a journal replay there is no live turn. A `turnStarted` without a
    /// matching `turnCompleted` means the process died mid-turn: if the
    /// response already made it to the journal the turn is effectively done,
    /// otherwise hand the opening message back so the agent can re-run it
    /// exactly once after activation.
    public mutating func normalizeAfterReplay() {
        // A journal can end between any pair of lifecycle events. Clear all
        // live-only status and make every request left in `running` explicit
        // so a stale request can never remain the dashboard's active one.
        for index in modelRequests.indices {
            if case .running = modelRequests[index].outcome {
                modelRequests[index].outcome = .interrupted
            }
        }

        if let turn = activeTurn {
            if let opening = turn.opening, !turn.responded {
                pendingTurnRerun = opening
            }
        }
        activeTurn = nil
        phase = .idle
        currentToolName = nil
    }

    /// Deterministic timestamp for legacy events that predate per-tool timing.
    private func replayTimestamp(for timestamp: Date?) -> Date {
        timestamp ?? activeTurn?.startedAt ?? Date(timeIntervalSince1970: 0)
    }

    /// Value-oriented reducer form used by projections and tests.
    public func applying(_ event: AgentEvent) -> AgentState {
        var next = self
        next.apply(event)
        return next
    }
}
