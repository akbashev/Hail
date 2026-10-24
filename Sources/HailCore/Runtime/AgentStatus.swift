/// What an agent is doing now. An agent does one thing at a time: asked while it's busy, it says
/// with what, and whoever asked decides what to do about it.
public enum AgentStatus: Codable, Sendable, Equatable {
    /// Doing nothing: it can be asked.
    case idle
    case busy(Busy)

    /// What a busy agent is doing.
    public enum Busy: Codable, Sendable, Equatable {
        /// Answering: from a turn's input, or a turn resumed after a restart, until its reply is
        /// recorded and its history is ready for the next.
        case responding
        /// Compacting its history, after a turn.
        case compacting
    }
}
