import HailCore

/// A completed conversation compaction: the oldest `archivedCount` thread entries
/// were folded into `summary`, which REPLACES the previous rolling summary
/// (the compactor folds ``PromptContext/contextSummary`` into the new one).
public struct ConversationCompaction: Sendable, Equatable {
    public var summary: String
    public var archivedCount: Int

    public init(summary: String, archivedCount: Int) {
        self.summary = summary
        self.archivedCount = archivedCount
    }
}

/// Explicit domain decision returned by a context compactor. “No work” is a
/// valid decision rather than absence of a result or a suppressed failure.
public enum CompactionDecision: Sendable, Equatable {
    case unchanged
    case compacted(ConversationCompaction)
}

/// The exact sections of one stateless model request. Keeping these sections
/// explicit lets a compactor replace only the conversation suffix without
/// reverse-engineering a prompt policy's output by position.
public struct PreparedRequest: Sendable {
    public struct ConversationEntry: Sendable {
        /// Index of the source ``ChatMessage`` in ``PromptContext``.
        public let sourceIndex: Int
        public let message: LLMMessage

        public init(sourceIndex: Int, message: LLMMessage) {
            self.sourceIndex = sourceIndex
            self.message = message
        }
    }

    public let prefix: [LLMMessage]
    public let conversation: [ConversationEntry]
    public let suffix: [LLMMessage]
    public let tools: [LLMToolSchema]

    public init(
        prefix: [LLMMessage],
        conversation: [ConversationEntry],
        suffix: [LLMMessage] = [],
        tools: [LLMToolSchema] = []
    ) {
        self.prefix = prefix
        self.conversation = conversation
        self.suffix = suffix
        self.tools = tools
    }

    /// The full request in provider order.
    public var messages: [LLMMessage] {
        prefix + conversation.map(\.message) + suffix
    }

    /// Returns a request with all rendered conversation entries whose source
    /// messages occur after the archived semantic prefix.
    public func retainingConversation(after sourceIndex: Int) -> PreparedRequest {
        PreparedRequest(
            prefix: prefix,
            conversation: conversation.filter { $0.sourceIndex >= sourceIndex },
            suffix: suffix,
            tools: tools
        )
    }

    /// Adds request-local messages and tool schemas without changing the
    /// policy-owned prefix or conversation mapping.
    public func appending(
        suffix additionalMessages: [LLMMessage],
        tools additionalTools: [LLMToolSchema]
    ) -> PreparedRequest {
        PreparedRequest(
            prefix: prefix,
            conversation: conversation,
            suffix: suffix + additionalMessages,
            tools: tools + additionalTools
        )
    }
}

/// Decides — before each request, for non-session-owning endpoints — whether
/// the assembled context needs compacting, and produces the rolling summary.
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
    /// Return `.unchanged` when the context fits the budget and no compaction is due.
    /// `request` is the exact request shape that would be sent, with the
    /// conversation section carrying source indices back to
    /// `PromptContext.conversationThread`. A compactor must preserve the
    /// prefix and suffix while replacing only that conversation section.
    func compact(
        context: PromptContext,
        request: PreparedRequest,
        summarize: @Sendable ([LLMMessage]) async throws -> String
    ) async throws -> CompactionDecision
}
