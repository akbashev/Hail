import AnyLanguageModel
import HailCore

/// Explicit domain decision returned by a context compactor. “No work” is a
/// valid decision rather than absence of a result or a suppressed failure.
public enum CompactionDecision<Output: Codable & Sendable & Generable>: Sendable {
    case unchanged
    case compacted(CompactionResult<Output>)
}

extension CompactionDecision: Equatable where Output: Equatable {}

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
    public let entries: [Transcript.Entry]
    public let maxOutputTokens: Int

    public init(entries: [Transcript.Entry], maxOutputTokens: Int) {
        self.entries = entries
        self.maxOutputTokens = maxOutputTokens
    }
}

/// The model-facing part of one compaction operation.
///
/// A host may generate any concrete `Generable` report. That report is erased
/// only at this Hail boundary, after the provider has received its concrete
/// schema. Hail still owns request accounting, compaction policy, persistence,
/// and replay.
public struct CompactionOperation: Sendable {
    public typealias Stream =
        @Sendable (
            _ endpoint: any ModelEndpoint,
            _ request: CompactionSummaryRequest,
            _ authority: any Authority
        ) -> AsyncStream<ModelEvent<GeneratedContent>>

    /// Budget passed to the host so it can fit the projected context summary
    /// deterministically instead of forcing a second model request.
    public typealias ContextProjection =
        @Sendable (
            _ generated: GeneratedContent,
            _ budget: ContextProjectionBudget
        ) throws(AgentRuntimeError) -> GeneratedContent

    public let stream: Stream
    public let contextProjection: ContextProjection

    public init(
        stream: @escaping Stream,
        contextProjection: @escaping ContextProjection
    ) {
        self.stream = stream
        self.contextProjection = contextProjection
    }
}

/// Token budget available for the context-projected part of a compaction
/// report. The host may degrade gracefully (drop sections, truncate) instead
/// of letting the runtime throw.
public struct ContextProjectionBudget: Sendable {
    /// Tokens the projected summary may consume inside the rebuilt request.
    public let availableTokens: Int
    /// Maximum tokens the summarizer was allowed to emit.
    public let outputReserve: Int

    public init(availableTokens: Int, outputReserve: Int) {
        self.availableTokens = max(0, availableTokens)
        self.outputReserve = max(0, outputReserve)
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
public typealias RequestMeasurer =
    @Sendable (
        PreparedRequest
    ) async throws(AgentRuntimeError) -> RequestMeasurement

/// The exact sections of one stateless model request. Keeping these sections
/// explicit lets a compactor replace only the conversation suffix without
/// reverse-engineering a prompt policy's output by position.
public struct PreparedRequest: Sendable {
    public struct ConversationEntry: Sendable {
        /// Index of the source ``ChatMessage`` in ``PromptContext``.
        public let sourceIndex: Int
        public let entry: Transcript.Entry

        public init(sourceIndex: Int, entry: Transcript.Entry) {
            self.sourceIndex = sourceIndex
            self.entry = entry
        }
    }

    public let prefix: [Transcript.Entry]
    public let conversation: [ConversationEntry]
    public let suffix: [Transcript.Entry]
    public let tools: [ToolDefinition]
    public init(
        prefix: [Transcript.Entry],
        conversation: [ConversationEntry],
        suffix: [Transcript.Entry] = [],
        tools: [ToolDefinition] = []
    ) {
        self.prefix = prefix
        self.conversation = conversation
        self.suffix = suffix
        self.tools = tools
    }

    /// The full request in provider order.
    public var entries: [Transcript.Entry] {
        prefix + conversation.map(\.entry) + suffix
    }

    /// Finds the provider-message position corresponding to one durable
    /// conversation source entry. The source index is stable across prompt
    /// rebuilds even when compaction changes the number of retained messages.
    func messageIndex(forSourceIndex sourceIndex: Int) -> Int? {
        guard
            let conversationIndex = conversation.lastIndex(where: {
                $0.sourceIndex == sourceIndex
            })
        else {
            return nil
        }
        return prefix.count + conversationIndex
    }

    /// Adds request-local messages and tool schemas without changing the
    /// policy-owned prefix or conversation mapping.
    public func appending(
        suffix additionalMessages: [Transcript.Entry],
        tools additionalTools: [ToolDefinition]
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
    /// Gives the compactor an opportunity to recover from a provider-reported
    /// overflow. `request` is the exact request shape that would be sent, with
    /// the conversation section carrying source indices back to
    /// `PromptContext.conversationThread`. A compactor must preserve the
    /// prefix and suffix while replacing only that conversation section.
    ///
    /// The summarizer's task text is derived from the report type itself
    /// (see ``CompactionTask``); hosts document their ``Generable`` report.
    func compact<Output: Codable & Sendable & Generable>(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measurement: RequestMeasurement?,
        measure: RequestMeasurer?,
        assemble: PromptAssembler,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
        contextProjection: @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError) -> GeneratedContent,
        trigger: ContextCompactionTrigger
    ) async throws(AgentRuntimeError) -> CompactionDecision<Output>
}

extension ContextCompactor {
    /// The ordinary call site does not need to know about endpoint-specific
    /// token counters or an overflow trigger. The runtime uses the full
    /// request-aware operation above; this helper keeps direct policy tests and
    /// simple hosts small.
    public func compact<Output: Codable & Sendable & Generable>(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
    ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
        try await compact(
            context: context,
            request: request,
            budget: budget,
            measurement: nil,
            measure: nil,
            assemble: assembleStandardPrompt,
            summarize: summarize,
            contextProjection: { value, _ in value.generatedContent },
            trigger: .threshold
        )
    }
}
