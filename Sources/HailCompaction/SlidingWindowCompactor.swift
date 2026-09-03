import Foundation
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
    /// Minimum number of semantic messages kept verbatim at the tail. The
    /// actual retained suffix is selected by token cost first.
    public var keepRecent: Int
    /// Space reserved for the next model response.
    public var outputReserve: Int
    /// Space reserved for a possible tool result in the next round.
    public var toolResultReserve: Int

    public init(
        budget: ContextWindowBudget = .init(),
        estimator: TokenEstimator = .init(),
        threshold: Double = 0.7,
        keepRecent: Int = 10,
        outputReserve: Int = 512,
        toolResultReserve: Int = 512
    ) {
        self.budget = budget
        self.estimator = estimator
        self.threshold = threshold
        self.keepRecent = keepRecent
        self.outputReserve = max(0, outputReserve)
        self.toolResultReserve = max(0, toolResultReserve)
    }

    public func compact(
        context: PromptContext,
        request: PreparedRequest,
        summarize: @Sendable ([LLMMessage]) async throws(AgentRuntimeError) -> String
    ) async throws(AgentRuntimeError) -> CompactionDecision {
        let window =
            context.measurement.effectiveContextWindow
            ?? budget.budget(for: context.definition.behavior.model.rawValue)
        let trigger = Int(Double(window) * threshold)

        let used: Int
        if let projected = context.measurement.projectedTokenCount {
            used = projected
        } else {
            used = try await measure(context: context, messages: request.messages, tools: request.tools)
        }
        guard used >= trigger else { return .unchanged }

        let minimumTail = max(keepRecent, 1)
        guard context.conversationThread.count > minimumTail else { return .unchanged }
        guard !request.conversation.isEmpty else {
            throw AgentRuntimeError.configurationError(
                "Context compaction requires a prepared conversation section"
            )
        }

        let hardLimit = max(window, 1)
        let retainedTarget = max(0, hardLimit - outputReserve - toolResultReserve)
        let validCuts = Self.validCuts(
            in: context.conversationThread,
            maximum: context.conversationThread.count - minimumTail,
            assistantSender: context.agentID.rawValue
        )
        guard !validCuts.isEmpty else { return .unchanged }

        // Find the smallest archive prefix whose complete request fits the
        // retained target. Since removing an older prefix only removes tokens,
        // valid cuts are monotonic and can be searched without trying every
        // possible suffix.
        var lower = 0
        var upper = validCuts.count - 1
        var selectedCut: Int?
        while lower <= upper {
            let middle = (lower + upper) / 2
            let cut = validCuts[middle]
            let candidate = request.retainingConversation(after: cut)
            let count = try await measure(
                context: context,
                messages: candidate.messages,
                tools: candidate.tools
            )
            if count <= retainedTarget {
                selectedCut = cut
                upper = middle - 1
            } else {
                lower = middle + 1
            }
        }

        guard let archivedCount = selectedCut else {
            // Even the minimum semantic tail cannot fit with the required
            // reserve. Sending this request would knowingly overflow the
            // configured window, so fail before the provider sees it.
            throw AgentRuntimeError.contextLengthExceeded
        }
        guard archivedCount > 0 else { return .unchanged }

        let archived = Array(context.conversationThread.prefix(archivedCount))
        let summary = try await summarizeInBoundedChunks(
            context: context,
            archived: archived,
            window: hardLimit,
            summarize: summarize
        )
        return .compacted(
            ConversationCompaction(summary: summary, archivedCount: archivedCount)
        )
    }

    /// Summarizes an archived prefix in bounded groups. A single large tool
    /// result or transcript must not make the summarization request itself
    /// exceed the same model window used for generation. Each completed chunk
    /// is folded into the next chunk's prior summary, producing one rolling
    /// summary and one atomic compaction event.
    private func summarizeInBoundedChunks(
        context: PromptContext,
        archived: [ChatMessage],
        window: Int,
        summarize: @Sendable ([LLMMessage]) async throws(AgentRuntimeError) -> String
    ) async throws(AgentRuntimeError) -> String {
        let summaryBudget = max(1, window - outputReserve)
        var rollingSummary = context.contextSummary
        var pending: [ChatMessage] = []

        for group in Self.messageGroups(archived, assistantSender: context.agentID.rawValue) {
            let candidate = pending + group
            let candidatePrompt = SummaryPrompt.messages(
                priorSummary: rollingSummary,
                archived: candidate,
                agentID: context.agentID
            )
            let candidateCost = try await measure(
                context: context,
                messages: candidatePrompt,
                tools: []
            )
            if candidateCost <= summaryBudget {
                pending = candidate
                continue
            }

            guard !pending.isEmpty else {
                // The smallest indivisible group cannot fit even after
                // reserving output space; sending it would knowingly exceed
                // the model window.
                throw AgentRuntimeError.contextLengthExceeded
            }

            rollingSummary = try await summarize(
                SummaryPrompt.messages(
                    priorSummary: rollingSummary,
                    archived: pending,
                    agentID: context.agentID
                ))
            pending = group

            let singlePrompt = SummaryPrompt.messages(
                priorSummary: rollingSummary,
                archived: pending,
                agentID: context.agentID
            )
            guard try await measure(context: context, messages: singlePrompt, tools: []) <= summaryBudget else {
                throw AgentRuntimeError.contextLengthExceeded
            }
        }

        guard !pending.isEmpty else {
            throw AgentRuntimeError.modelMisbehavior("Compaction produced no summary input")
        }
        return try await summarize(
            SummaryPrompt.messages(
                priorSummary: rollingSummary,
                archived: pending,
                agentID: context.agentID
            ))
    }

    // MARK: - Budget fitting

    /// Returns archive boundaries that do not split a tool call from any of
    /// its results. A cut at `n` archives `0..<n` and retains `n...`.
    private static func validCuts(
        in thread: [ChatMessage],
        maximum: Int,
        assistantSender: String
    ) -> [Int] {
        let groups = interactionBounds(in: thread, assistantSender: assistantSender)
        return (0...max(0, maximum)).filter { cut in
            groups.allSatisfy { bounds in
                !(bounds.first < cut && bounds.last >= cut)
            }
        }
    }

    /// Groups a tool-call message with every result belonging to it. This is
    /// used while chunking summary input so a summarizer never sees half of a
    /// parallel tool interaction.
    private static func messageGroups(
        _ messages: [ChatMessage],
        assistantSender: String
    ) -> [[ChatMessage]] {
        let interactions = interactionBounds(in: messages, assistantSender: assistantSender)
        let byStart = Dictionary(uniqueKeysWithValues: interactions.map { ($0.first, $0) })
        var groups: [[ChatMessage]] = []
        var index = 0
        while index < messages.count {
            let end = byStart[index]?.last ?? index
            let groupEnd = min(end, messages.count - 1)
            groups.append(Array(messages[index...groupEnd]))
            index = groupEnd + 1
        }
        return groups
    }

    /// Finds tool interactions by occurrence, not by globally unique tool ID.
    /// IDs are only used to associate a result with the earliest still-open
    /// call occurrence; repeated IDs in later rounds therefore remain separate.
    private static func interactionBounds(
        in messages: [ChatMessage],
        assistantSender: String
    ) -> [(first: Int, last: Int)] {
        var groups: [(first: Int, last: Int)] = []
        var pending: [String: [Int]] = [:]

        for (index, message) in messages.enumerated() {
            switch message {
            case .toolCall(let calls, _):
                let first: Int
                if index > 0,
                    case .text(let sender, _, _) = messages[index - 1], sender == assistantSender
                {
                    first = index - 1
                } else {
                    first = index
                }
                let groupIndex = groups.count
                groups.append((first: first, last: index))
                for call in calls {
                    pending[call.id, default: []].append(groupIndex)
                }

            case .toolResult(let id, _, _):
                if var occurrences = pending[id], !occurrences.isEmpty {
                    let groupIndex = occurrences.removeFirst()
                    pending[id] = occurrences
                    groups[groupIndex].last = max(groups[groupIndex].last, index)
                } else {
                    // Orphaned results are still indivisible transcript items.
                    groups.append((first: index, last: index))
                }

            default:
                break
            }
        }

        // A delayed result can make interactions overlap. Merge overlapping
        // ranges so no valid boundary can split either interaction.
        let sorted = groups.sorted { $0.first < $1.first }
        var merged: [(first: Int, last: Int)] = []
        for group in sorted {
            if let last = merged.indices.last, group.first <= merged[last].last {
                merged[last].last = max(merged[last].last, group.last)
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    /// Measures a candidate with the endpoint's tokenizer when one was
    /// injected by the runtime. Unsupported counting uses the estimator;
    /// failure of a supported counter propagates.
    private func measure(
        context: PromptContext,
        messages: [LLMMessage],
        tools: [LLMToolSchema]
    ) async throws(AgentRuntimeError) -> Int {
        switch context.measurement.tokenCounting {
        case .available(let counter):
            return max(0, try await counter(messages, tools))
        case .unavailable:
            return try await estimator.estimate(messages: messages, tools: tools)
        }
    }
}
