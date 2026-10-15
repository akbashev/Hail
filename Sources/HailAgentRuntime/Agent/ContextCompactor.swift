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

/// Measures a candidate request with the provider's own counter.
public typealias RequestMeasurer =
    @Sendable (
        PreparedRequest
    ) async throws(AgentRuntimeError) -> RequestMeasurement

/// How compaction knows a request's size.
public enum RequestMeasuring: Sendable {
    /// The provider counts: `current` is the request's exact size, and `by` counts candidates.
    case counted(RequestMeasurement, by: RequestMeasurer)
    /// The provider's last report, a floor for the request's size, since a history only grows;
    /// candidates are estimated.
    case reportedFloor(RequestMeasurement)
    /// Only Hail's estimate, for the request and its candidates.
    case estimated
}

/// The sections of one stateless model request, in the order the model reads them: the prefix
/// (instructions and the summary), the history before the open turn, and the open turn. Every
/// entry is something that happened: what was said, what the model said, and its calls with
/// their results. A compactor replaces the history and the open turn's work, never the prefix's
/// instructions.
public struct PreparedRequest: Sendable {
    public let prefix: [Transcript.Entry]
    public let history: [Transcript.Entry]
    /// What the open turn answers, then its work so far.
    public let openTurn: [Transcript.Entry]
    public let tools: [ToolDefinition]

    public init(
        prefix: [Transcript.Entry],
        history: [Transcript.Entry],
        openTurn: [Transcript.Entry],
        tools: [ToolDefinition] = []
    ) {
        self.prefix = prefix
        self.history = history
        self.openTurn = openTurn
        self.tools = tools
    }

    /// The full request in provider order.
    public var entries: [Transcript.Entry] {
        prefix + history + openTurn
    }

    /// The request with the tools its turn offers.
    public func offering(_ tools: [ToolDefinition]) -> PreparedRequest {
        PreparedRequest(prefix: prefix, history: history, openTurn: openTurn, tools: self.tools + tools)
    }

    /// The request with what arrived since the last turn: calls that finished meanwhile, which
    /// arrive with what the turn answers, in the same message.
    public func receiving(_ arrivals: [Arrival]) -> PreparedRequest {
        guard !arrivals.isEmpty, case .prompt(let input)? = openTurn.first else { return self }
        let arrived = arrivals.map { arrival in
            Transcript.Segment.text(.init(content: "\(arrival.call.name) finished meanwhile: \(arrival.output.textRepresentation)"))
        }
        return PreparedRequest(
            prefix: prefix, history: history, openTurn: [.prompt(.init(segments: input.segments + arrived))] + openTurn.dropFirst(),
            tools: tools)
    }
}

/// Decides — after each turn, and when a request overflows, for non-session-owning endpoints —
/// whether the context needs compacting, and produces the rolling summary.
///
/// Session-owning harnesses (kimi/claude/codex) manage context in their own
/// sessions and are never offered compaction. Stateless chat endpoints
/// (Ollama, hosted chat APIs) have no server-side memory management, so the
/// agent runtime owns it here.
///
/// The result is journaled as a single ``AgentHistory/Event/compacted(_:through:kept:)``
/// event: the summary is a non-deterministic fold of the archived work, so it must be
/// recorded — replay never re-runs the summarizer. Snapshotting checkpoints
/// the resulting state; the journal stays the source of truth.
///
/// `summarize` is supplied by the runtime and backed by the turn's own model
/// endpoint; hosts wanting a different (cheaper) summarizer model implement
/// this protocol themselves or wrap the injected closure.
public protocol ContextCompactor: Sendable {
    /// Gives the compactor an opportunity to recover from a provider-reported
    /// overflow. `request` is the exact request shape that would be sent. A compactor decides which
    /// turns' work goes into the summary, and which archived inputs stay word for word.
    ///
    /// The summarizer's task text is derived from the report type itself
    /// (see ``CompactionTask``); hosts document their ``Generable`` report.
    func compact<Output: Codable & Sendable & Generable>(
        context: PromptContext,
        request: PreparedRequest,
        budget: CompactionBudget,
        measuring: RequestMeasuring,
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
            measuring: .estimated,
            assemble: assembleStandardPrompt,
            summarize: summarize,
            contextProjection: { value, _ in value.generatedContent },
            trigger: .threshold
        )
    }
}
