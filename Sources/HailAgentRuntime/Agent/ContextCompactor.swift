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

/// Explains why a compactor was asked to make a decision. A provider-reported
/// context failure is different from the normal occupancy threshold: it must
/// be allowed to compact even when Hail's fallback estimate did not predict
/// the failure.
public enum ContextCompactionTrigger: Sendable, Equatable {
    case threshold
    case contextLengthExceeded
}

/// The validated context capacity for one compaction decision.
///
/// It is resolved by the runtime from the selected model boundary before the
/// functional compaction policy runs. The policy therefore never has to look
/// up a model or invent a fallback window.
public struct CompactionBudget: Sendable, Equatable {
    public let contextWindow: Int

    public init(contextWindow: Int) throws(AgentRuntimeError) {
        guard contextWindow > 0 else {
            throw .configurationError(
                "Context compaction requires a positive context window, got \(contextWindow)."
            )
        }
        self.contextWindow = contextWindow
    }

    /// Resolves the maximum summary size from context capacity. The policy
    /// grows in steps so larger contexts get more room without turning the
    /// summary into another full conversation.
    public func outputReserve(maximum: Int) -> Int {
        let target: Int
        switch contextWindow {
        case ..<8_192:
            target = 2_048
        case ..<65_536:
            target = 4_096
        default:
            target = 8_192
        }
        return min(maximum, target, max(1, contextWindow - 1))
    }
}

/// The exact input and output allowance for one summarization request.
public struct CompactionSummaryRequest: Sendable {
    public let messages: [LLMMessage]
    public let maxOutputTokens: Int

    public init(messages: [LLMMessage], maxOutputTokens: Int) {
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
    }
}

/// The size of one assembled request as observed by the runtime or estimated
/// by a compactor. This is request data, not agent context.
public struct RequestMeasurement: Sendable, Equatable {
    public let tokenCount: Int
    public let source: ModelMeasurementSource

    public init(tokenCount: Int, source: ModelMeasurementSource) {
        self.tokenCount = max(0, tokenCount)
        self.source = source
    }
}

/// Measures a candidate request. Compaction uses this for candidate cuts and
/// summary chunks; the initial request measurement is passed separately so it
/// is not recomputed or hidden inside the agent context.
public typealias RequestMeasurer = @Sendable (
    PreparedRequest
) async throws(AgentRuntimeError) -> RequestMeasurement

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
    /// Rich request input for provider-aware token counting. Ordinary prompt
    /// assembly leaves this nil; the reasoning loop supplies it after a tool
    /// round so artifact bodies are included in the budget.
    public let input: ModelInput?

    public init(
        prefix: [LLMMessage],
        conversation: [ConversationEntry],
        suffix: [LLMMessage] = [],
        tools: [LLMToolSchema] = [],
        input: ModelInput? = nil
    ) {
        self.prefix = prefix
        self.conversation = conversation
        self.suffix = suffix
        self.tools = tools
        self.input = input
    }

    /// The full request in provider order.
    public var messages: [LLMMessage] {
        prefix + conversation.map(\.message) + suffix
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
            tools: tools + additionalTools,
            input: input
        )
    }

    public func withInput(_ input: ModelInput?) -> PreparedRequest {
        PreparedRequest(
            prefix: prefix,
            conversation: conversation,
            suffix: suffix,
            tools: tools,
            input: input
        )
    }

    /// Rebuilds rich input for a candidate whose semantic conversation has
    /// been trimmed by a compactor. This method is called on the source
    /// request, so it can distinguish archived tool results from live outputs
    /// that have not entered the durable conversation yet.
    public func input(for messages: [LLMMessage]) -> ModelInput {
        guard let input else { return ModelInput(messages: messages) }

        // A live tool output can exist in `input` before its semantic result
        // has reached the durable conversation thread. Keep those entries in
        // the request, but do not resurrect an output whose tool-result
        // message was deliberately archived from this request.
        let representedToolResultIDs = Set(
            self.messages.compactMap { message in
                message.role == .tool ? message.toolCallID : nil
            }
        )
        let liveOutputs = input.richOutputMessages.filter { message in
            !representedToolResultIDs.contains(message.toolCallID ?? "")
        }
        return input.rebased(on: messages + liveOutputs)
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
    /// Gives the compactor an opportunity to recover from a provider-reported
    /// overflow. `request` is the exact request shape that would be sent, with
    /// the conversation section carrying source indices back to
    /// `PromptContext.conversationThread`. A compactor must preserve the
    /// prefix and suffix while replacing only that conversation section.
    func compact(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measurement: RequestMeasurement?,
        measure: RequestMeasurer?,
        assemble: PromptAssembler,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String,
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision
}

extension ContextCompactor {
    /// The ordinary call site does not need to know about endpoint-specific
    /// token counters or an overflow trigger. The runtime uses the full
    /// request-aware operation above; this helper keeps direct policy tests and
    /// simple hosts small.
    public func compact(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String
    ) async throws(AgentRuntimeError) -> CompactionDecision {
        try await compact(
            context: context,
            request: request,
            budget: budget,
            measurement: nil,
            measure: nil,
            assemble: assembleStandardPrompt,
            summarize: summarize,
            trigger: .threshold
        )
    }
}
