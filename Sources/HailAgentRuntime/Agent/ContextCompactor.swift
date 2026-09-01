import HailCore

/// The outcome of a compaction: the oldest `archivedCount` thread entries
/// were folded into `summary`, which REPLACES the previous rolling summary
/// (the compactor folds ``PromptContext/contextSummary`` into the new one).
public struct CompactionResult: Sendable, Equatable {
    public var summary: String
    public var archivedCount: Int

    public init(summary: String, archivedCount: Int) {
        self.summary = summary
        self.archivedCount = archivedCount
    }
}

/// Decides — at turn start, for non-session-owning endpoints — whether the
/// assembled context needs compacting, and produces the rolling summary.
///
/// Session-owning harnesses (kimi/claude/codex) manage context in their own
/// sessions and are never offered compaction. Stateless chat endpoints
/// (Ollama, hosted chat APIs) have no server-side memory management, so the
/// agent runtime owns it here.
///
/// The result is journaled as a single
/// ``AgentEvent/conversationCompacted(archivedCount:summary:)`` event: the
/// summary is a non-deterministic fold of the archived prefix, so it must be
/// recorded — replay never re-runs the summarizer. Snapshotting checkpoints
/// the resulting state; the journal stays the source of truth.
///
/// `summarize` is supplied by the runtime and backed by the turn's own model
/// endpoint; hosts wanting a different (cheaper) summarizer model implement
/// this protocol themselves or wrap the injected closure.
public protocol ContextCompactor: Sendable {
    /// Return nil when the context fits the budget and no compaction is due.
    func compact(
        context: PromptContext,
        /// The complete messages that would be sent if compaction did not run,
        /// including per-turn instructions and the current input.
        messages: [LLMMessage],
        /// Tool definitions consume the same model context window as messages.
        tools: [LLMToolSchema],
        summarize: @Sendable ([LLMMessage]) async throws -> String
    ) async throws -> CompactionResult?
}
