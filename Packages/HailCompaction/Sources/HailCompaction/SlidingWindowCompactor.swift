import HailAgentRuntime
import HailCore

/// The reference ``ContextCompactor``: triggers at a fraction of the model's
/// context window, folds the oldest messages into the rolling summary, and
/// keeps the most recent ones verbatim.
///
/// Boundary rules:
/// - the newest `keepRecent` messages are never archived — at minimum the
///   last one, which opened the turn currently running;
/// - a cut never splits a ``ChatMessage/toolCall`` from its
///   ``ChatMessage/toolResult``(s): a trailing tool call in the archived
///   prefix backs the cut off until the prefix ends cleanly;
/// - the existing ``PromptContext/contextSummary`` is folded into the new
///   summary by the summarize closure, so the window carries at most one.
public struct SlidingWindowCompactor: ContextCompactor {
    public var budget: ContextWindowBudget
    public var estimator: TokenEstimator
    /// Fraction of the window at which compaction triggers.
    public var threshold: Double
    /// Messages kept verbatim at the tail of the thread.
    public var keepRecent: Int

    public init(
        budget: ContextWindowBudget = .init(),
        estimator: TokenEstimator = .init(),
        threshold: Double = 0.7,
        keepRecent: Int = 10
    ) {
        self.budget = budget
        self.estimator = estimator
        self.threshold = threshold
        self.keepRecent = keepRecent
    }

    public func compact(
        context: PromptContext,
        messages: [LLMMessage],
        tools: [LLMToolSchema],
        summarize: @Sendable ([LLMMessage]) async throws -> String
    ) async throws -> CompactionResult? {
        let window = budget.budget(for: context.definition.behavior.model)
        let trigger = Int(Double(window) * threshold)

        let used = await estimator.estimate(messages: messages, tools: tools)
        guard used >= trigger else { return nil }

        let keep = max(keepRecent, 1)
        guard context.conversationThread.count > keep else { return nil }
        var archivedCount = context.conversationThread.count - keep

        // Move the cut before any tool interaction that crosses it. Looking
        // only at the message immediately before the cut is insufficient for
        // parallel tool calls, where one result can precede another result
        // that would otherwise be left orphaned in the retained suffix.
        var toolBounds: [String: (first: Int, last: Int)] = [:]
        for (index, message) in context.conversationThread.enumerated() {
            let ids: [String]
            switch message {
            case .toolCall(let calls, _):
                ids = calls.map(\.id)
            case .toolResult(let id, _, _):
                ids = [id]
            default:
                ids = []
            }
            for id in ids {
                if let bounds = toolBounds[id] {
                    toolBounds[id] = (bounds.first, index)
                } else {
                    toolBounds[id] = (index, index)
                }
            }
        }
        while archivedCount > 0 {
            let adjusted = toolBounds.values.reduce(archivedCount) { cut, bounds in
                guard bounds.first < archivedCount, bounds.last >= archivedCount else { return cut }
                return min(cut, bounds.first)
            }
            guard adjusted != archivedCount else { break }
            archivedCount = adjusted
        }
        guard archivedCount > 0 else { return nil }

        let archived = Array(context.conversationThread.prefix(archivedCount))
        let prompt = SummaryPrompt.messages(
            priorSummary: context.contextSummary,
            archived: archived,
            agentID: context.agentID
        )
        let summary = try await summarize(prompt)
        return CompactionResult(summary: summary, archivedCount: archivedCount)
    }

    /// Convenience for callers that do not have per-turn additions or tools.
    /// Runtime integrations should pass the exact projected request through
    /// the protocol requirement above.
    public func compact(
        context: PromptContext,
        summarize: @Sendable ([LLMMessage]) async throws -> String
    ) async throws -> CompactionResult? {
        try await compact(
            context: context,
            messages: PromptPolicy.default.build(context),
            tools: [],
            summarize: summarize
        )
    }
}
