import AnyLanguageModel

/// Indicates whether a token count came from the provider/tokenizer or from a
/// conservative Hail-side estimate.
public enum ModelMeasurementSource: Codable, Sendable, Equatable {
    case reported
    case estimated
}

/// Token consumption for one model request. Providers are free to omit fields
/// they do not report; `nil` means unknown, never zero.
public struct ModelUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cachedReadTokens: Int?
    public var cachedWriteTokens: Int?
    public var totalTokens: Int?
    public var source: ModelMeasurementSource

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cachedReadTokens: Int? = nil,
        cachedWriteTokens: Int? = nil,
        totalTokens: Int? = nil,
        source: ModelMeasurementSource
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.totalTokens = totalTokens
        self.source = source
    }
}

/// The model-visible context occupancy reported by a session-owning harness or
/// measured by a runtime-owned endpoint.
public struct ContextUsage: Codable, Sendable, Equatable {
    public var usedTokens: Int
    public var limitTokens: Int
    public var source: ModelMeasurementSource

    public init(usedTokens: Int, limitTokens: Int, source: ModelMeasurementSource) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.source = source
    }
}

/// Non-terminal provider activity. Activity never becomes the model result.
public enum ModelActivity: Sendable, Equatable {
    case narrationDelta(GeneratedContent)
    case reasoningDelta(GeneratedContent)
    case status(GeneratedContent)
}

/// The complete assistant response that ended a model request by asking Hail
/// to execute tools. Providers assemble this value at their transport
/// boundary. The reasoning loop receives an already completed round and never
/// reconstructs it from activity fragments.
public struct ModelToolRound: Codable, Sendable, Equatable {
    /// Assistant-visible content, when the provider emitted any before the
    /// tool calls. Transcript segments preserve structured content without
    /// reducing it to a text sentinel.
    public let narration: Transcript.Response?

    /// Provider reasoning retained for protocols that require it to accompany
    /// the subsequent tool result. AnyLanguageModel has no native reasoning
    /// segment, so Hail preserves it as ordered transcript segments.
    public let reasoning: [Transcript.Segment]

    /// Complete tool calls with their provider-native generated arguments.
    public let calls: [ToolCall]

    public init(
        narration: Transcript.Response? = nil,
        reasoning: [Transcript.Segment] = [],
        calls: [ToolCall]
    ) {
        self.narration = narration
        self.reasoning = reasoning
        self.calls = calls
    }
}

/// Events emitted by a model during a streaming turn.
public enum ModelEvent<Output>: Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
    /// Non-terminal provider activity.
    case activity(ModelActivity)

    /// A complete assistant round requesting one or more tools. The caller
    /// executes the tools and feeds their results back into the next turn.
    case toolsRequested(ModelToolRound)

    /// A partial generated value as it is being generated. Providers that
    /// support native streaming yield cumulative snapshots; plain-text typed
    /// streams may also emit these alongside their text deltas.
    case partialUpdated(Output.PartiallyGenerated)

    /// Token consumption for the request, when the endpoint can report it.
    case usage(ModelUsage)

    /// Current context occupancy, when the endpoint can report it.
    case contextUsage(ContextUsage)

    /// The only successful terminal result of the turn.
    case generated(Output)

    /// The turn failed.
    case failed(ModelEndpointError)
}

extension ModelEvent: Equatable where Output: Equatable, Output.PartiallyGenerated: Equatable {}

/// Identifies which layer owns the model-visible conversation window.
///
/// Every endpoint must choose explicitly. Runtime-owned endpoints receive an
/// assembled transcript on every request and may use Hail's context compactor.
/// Endpoint-session-owned endpoints receive turn deltas after bootstrap and
/// manage their own context window behind ``SessionOwningEndpoint``.
public enum ModelContextOwnership: Sendable, Equatable {
    case runtime
    case endpointSession
}

/// The semantic purpose of a model request. Providers can use this to apply
/// operation-specific limits without making compaction a provider-specific
/// concern in the reasoning loop.
public enum ModelRequestPurpose: Sendable, Equatable {
    case generation
    case compaction(maxOutputTokens: Int)
}

/// Exact-token-counting capability of a model endpoint. Unsupported counting
/// is represented as domain data; once a counter is available, failure to use
/// it remains an error rather than being encoded as another optional value.
public enum TokenCounting: Sendable {
    case unavailable
    case available(
        @Sendable (_ entries: [Transcript.Entry], _ tools: [ToolDefinition]) async throws(AgentRuntimeError) -> Int
    )
}

public protocol ModelEndpoint: Sendable {
    var model: String { get }
    var contextOwnership: ModelContextOwnership { get }

    /// The effective context limit configured for this endpoint, if known.
    /// This is preferred over a model-name lookup because local servers often
    /// run with a smaller request-level limit than the model supports.
    var effectiveContextWindow: Int? { get }

    /// Exact request-counting capability for this endpoint.
    var tokenCounting: TokenCounting { get }

    /// Streams one model turn with an explicitly declared generated value.
    /// The provider owns the transport and decoding details; Hail only sees
    /// typed partials, tool calls, usage, and the completed value.
    func stream<Input, Output>(
        input: Input,
        entries: [Transcript.Entry],
        tools: [AnyTool],
        authority: any Authority,
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable,
        Output.PartiallyGenerated: Sendable
}

// MARK: - Default structured fallback

extension ModelEndpoint {
    public var effectiveContextWindow: Int? { nil }

    public var tokenCounting: TokenCounting { .unavailable }

}

public enum ModelEndpointError: Error, Sendable, Equatable {
    case configuration(String)
    case authentication
    case unavailable
    case rateLimit
    case contextLengthExceeded
    case invalidRequest(String)
    case requestFailed(String)
    case invalidResponse(String)
    case decodingError(String)
    case cancelled
}

public enum HailErrorFormatter {
    public static func userFacingMessage(_ error: any Error) -> String {
        switch error {
        case let modelError as ModelEndpointError:
            return message(for: modelError)
        case let runtimeError as AgentRuntimeError:
            return message(for: runtimeError)
        default:
            return String(describing: error)
        }
    }

    private static func message(for error: AgentRuntimeError) -> String {
        switch error {
        case .modelMisbehavior(let reason):
            "Model error: \(sanitizedModelOutput(reason))"
        case .modelUnavailable:
            "The model service is currently unavailable."
        case .rateLimit:
            "Rate limit hit. Please retry later."
        case .contextLengthExceeded:
            "Context length exceeded. The conversation is too long for this model."
        case .configurationError(let reason):
            "Configuration error: \(reason)"
        case .infrastructureFailure(let reason):
            "Infrastructure error: \(reason)"
        case .persistenceFailure(let reason):
            "Persistence error: \(reason)"
        case .toolFailed(let name, let reason):
            "Tool '\(name)' failed: \(reason)"
        case .cancelled:
            "The run was cancelled."
        case .sandboxViolation(let reason):
            "Sandbox violation: \(reason)"
        }
    }

    private static func message(for error: ModelEndpointError) -> String {
        switch error {
        case .configuration(let reason):
            return "Configuration error: \(reason)"
        case .authentication:
            return "Authentication failed. Check your API key or credentials."
        case .unavailable:
            return "The model service is currently unavailable."
        case .rateLimit:
            return "Rate limit hit. Please retry later."
        case .contextLengthExceeded:
            return "Context length exceeded. The conversation is too long for this model."
        case .invalidRequest(let reason):
            return "Invalid request: \(reason)"
        case .requestFailed(let reason):
            return extractErrorLine(from: reason) ?? reason
        case .invalidResponse(let reason):
            return "Invalid model response: \(reason)"
        case .decodingError(let underlying):
            return "Failed to decode model response: \(underlying)"
        case .cancelled:
            return "Model request was cancelled."
        }
    }

    private static func extractErrorLine(from output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let errorLine = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(errorLine.dropFirst("ERROR:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return lines.last
    }

    public static func sanitizedModelOutput(_ output: String) -> String {
        return extractErrorLine(from: output) ?? output
    }
}
