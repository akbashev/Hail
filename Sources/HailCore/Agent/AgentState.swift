#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The event-sourced state of an ``Agent``. Kept as a separate value type so
/// the state transition can be tested and replayed without a distributed actor.
public struct AgentState: Codable, Sendable {
    public var agentID: AgentID
    public var conversationThread: [ChatMessage]
    public var workingMemory: [String]

    /// The turn currently in flight, if any. Set by `turnStarted`, cleared by
    /// `turnCompleted`. `opening` is the message that opened the turn (once
    /// journaled); `responded` records that a response made it to the journal.
    public private(set) var activeTurn: ActiveTurn?

    /// The opening message of a turn interrupted by a crash, folded by
    /// ``normalizeAfterReplay()``. The agent re-runs it after activation (when
    /// configured to). It is NOT cleared by `turnStarted`: the re-run starts a
    /// fresh turn before re-journaling its opening, so the marker must survive
    /// until `messageReceived` can recognize — and collapse — the duplicate.
    /// A non-matching opening clears it as stale.
    public private(set) var pendingTurnRerun: ChatMessage?

    /// The harness session this agent's turns run in (kimi/claude CLI), if
    /// journaled. Used to resume the session after a restart.
    public private(set) var modelSessionID: SessionID?

    /// The identity fingerprint the harness session was created with.
    public private(set) var modelSessionIdentity: SessionIdentity?

    /// A reasoning turn in progress.
    public struct ActiveTurn: Codable, Sendable, Equatable {
        public var opening: ChatMessage?
        public var responded: Bool

        public init(opening: ChatMessage? = nil, responded: Bool = false) {
            self.opening = opening
            self.responded = responded
        }
    }

    public init(
        agentID: AgentID,
        conversationThread: [ChatMessage] = [],
        workingMemory: [String] = []
    ) {
        self.agentID = agentID
        self.conversationThread = conversationThread
        self.workingMemory = workingMemory
    }

    /// Apply a single event to this state. This is the only place where event
    /// replay mutates agent state, making the transition deterministic and
    /// testable.
    public mutating func apply(_ event: AgentEvent, maxMemoryFragments: Int) {
        switch event {
        case .activated(let agentID):
            self.agentID = agentID
        case .turnStarted:
            // Deliberately keeps `pendingTurnRerun`: the crash-recovery re-run
            // starts a fresh turn before re-journaling its opening, so the
            // marker must survive until `messageReceived` recognizes it.
            activeTurn = ActiveTurn()
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
        case .contextSet:
            // Context is part of the immutable agent identity; no state change.
            break
        case .toolInvoked(let toolCall, let at):
            // The fold prefers the journaled timestamp so replay is
            // deterministic; `Date()` is only the fallback for events written
            // before turn timing existed.
            conversationThread.append(
                .toolCall(calls: [toolCall], timestamp: at ?? Date())
            )
        case .toolResult(let result, let at):
            conversationThread.append(
                .toolResult(id: result.toolCallID, content: result.output, timestamp: at ?? Date())
            )
        case .memoryCommitted(let summary):
            workingMemory.append(summary)
            let maxFragments = max(0, maxMemoryFragments)
            if maxFragments > 0 && workingMemory.count > maxFragments {
                workingMemory.removeFirst(workingMemory.count - maxFragments)
            }
        case .conversationCompacted(let archivedCount):
            if archivedCount > 0 && archivedCount <= conversationThread.count {
                conversationThread.removeFirst(archivedCount)
            }
        case .responseReceived(let sender, let payload, let timestamp):
            conversationThread.append(.response(sender: sender, payload: payload, timestamp: timestamp))
            activeTurn?.responded = true
        case .turnFailed(let error, let at):
            conversationThread.append(.failure(error: error, timestamp: at))
        case .turnCompleted:
            activeTurn = nil
        case .modelSessionIdentified(let id, let identity):
            modelSessionID = id
            modelSessionIdentity = identity
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
        guard let turn = activeTurn else { return }
        activeTurn = nil
        if let opening = turn.opening, !turn.responded {
            pendingTurnRerun = opening
        }
    }
}
