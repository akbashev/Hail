import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An ephemeral, cluster-safe activity fragment emitted by an agent — either
/// a turn unfolding or a display message.
///
/// Activity is narration, never control: nothing here is journaled and nothing
/// here carries a typed outcome. Subscribers (chat, host views, a freshly
/// opened browser) consume it with `for await activity in agent`.
/// The hard rule: never derive control flow from activity —
/// the typed result rides the turn's ``AgentConnection``.
public enum AgentActivity: Codable, Sendable, Equatable {
    /// One unit of work, unfolding over time: it starts, reports progress
    /// zero or more times, and completes. Progress cannot exist outside a
    /// turn, so it lives inside this ADT rather than beside it. Live-state
    /// consumers (e.g. the `AgentObserver` computing which agents are
    /// currently working) consider an agent working between `.started` and
    /// `.completed`.
    public enum Turn: Codable, Sendable, Equatable {
        /// The turn's opening bracket, emitted alongside the journaled
        /// `turnStarted` event.
        case started
        /// Live narration of the work inside the turn.
        case progress(Progress)
        /// The turn's closing bracket, emitted alongside the journaled
        /// `turnCompleted` event.
        case completed
    }

    /// The work reported while a turn runs — status lines, reasoning traces,
    /// streamed reply text, and tool calls.
    public enum Progress: Codable, Sendable, Equatable {
        case status(GeneratedContent)
        /// Model reasoning output (distinct from reply text).
        case reasoning(GeneratedContent)
        case narration(GeneratedContent)
        case tool(name: String)
        /// Token usage reported by the model provider for the current request.
        case usage(ModelUsage)
        /// Current context occupancy reported by a session-owning endpoint.
        case contextUsage(ContextUsage)
    }

    /// A turn unfolding (see ``Turn``).
    case turn(Turn, at: Date)
    /// A display-only message journaled into the conversation thread via
    /// ``Agent/post(_:)`` (e.g. a supervisor decision request). Unlike turn
    /// activity this one mirrors a durable journal entry, so live and
    /// reloaded transcripts match. Display posts start no turn.
    case message(ChatMessage, at: Date)

    public var timestamp: Date {
        switch self {
        case .turn(_, let at), .message(_, let at):
            return at
        }
    }

    public var statusMessage: GeneratedContent? {
        switch self {
        case .turn(.progress(.status(let message)), _):
            return message
        case .turn, .message:
            return nil
        }
    }
}
