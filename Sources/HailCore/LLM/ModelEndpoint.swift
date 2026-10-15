import AnyLanguageModel
import Synchronization

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

/// A tool call a model makes inside its request: the session the request runs in runs it and
/// replies; the request waits for the reply, then goes on, in the same request.
public struct ModelToolCall: Sendable {
    public let call: ToolCall
    public let reply: ToolReply

    public init(call: ToolCall, reply: ToolReply) {
        self.call = call
        self.reply = reply
    }
}

/// What the session gives back for a tool call: the call's result, and the tools it offers now,
/// for the rest of the request.
public struct ToolAnswer: Sendable {
    /// What the call did, as the history keeps it.
    public let result: ToolResult
    /// The page it landed on, as it is now: read after the result, in this request only.
    public let page: ToolPage?
    public let tools: [AnyTool]

    public init(result: ToolResult, page: ToolPage? = nil, tools: [AnyTool]) {
        self.result = result
        self.page = page
        self.tools = tools
    }

    /// What the model reads for the call: the result, then the page it landed on.
    public var reading: String {
        ([result.output.textRepresentation] + (page.map { [$0.reading] } ?? []))
            .joined(separator: "\n\n")
    }
}

/// The way back to the request for one tool call's answer.
public struct ToolReply: Sendable {
    private let continuation: AsyncStream<ToolAnswer>.Continuation

    /// For the endpoint: a reply to hand out with the call, and the answer it waits for. The wait
    /// ends without an answer if the request is cancelled first.
    public static func awaiting() -> (reply: ToolReply, answer: AsyncStream<ToolAnswer>) {
        let (answer, continuation) = AsyncStream.makeStream(of: ToolAnswer.self, bufferingPolicy: .bufferingNewest(1))
        return (ToolReply(continuation: continuation), answer)
    }

    /// Answers the call; the first answer is the one the request goes on with.
    public func give(_ answer: ToolAnswer) {
        continuation.yield(answer)
        continuation.finish()
    }
}

/// Events emitted by a model during a streaming turn.
public enum ModelEvent<Output>: Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
    /// Non-terminal provider activity.
    case activity(ModelActivity)

    /// A tool call the model makes inside its request. The session the request runs in runs it
    /// and answers; the model goes on with the answer, in the same request.
    case toolCall(ModelToolCall)

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
    /// One bounded answer, such as the code a tool asks a model to write: thinking and answer
    /// together end at `maxOutputTokens`, so an answer that never ends still does.
    case writing(maxOutputTokens: Int)
}

/// An optional per-request override for a model's reasoning behavior.
/// ``providerDefault`` preserves the endpoint's configured behavior; providers
/// that expose an explicit switch may honor ``enabled`` or ``disabled``.
public enum ModelReasoningOverride: Sendable, Equatable {
    case providerDefault
    case enabled
    case disabled
}

/// How the previous tool round of a turn went, for a reasoning policy that thinks again
/// after a failure.
public enum ToolRoundOutcome: Sendable, Equatable {
    case succeeded
    /// At least one of its tool calls failed.
    case failed
}

/// Context supplied to a host's reasoning policy before Hail creates one
/// model request. This deliberately contains turn structure, not prompt text:
/// hosts can make an explicit policy decision without making Hail classify
/// user language.
public struct ModelReasoningContext: Sendable, Equatable {
    public let model: String
    public let purpose: ModelRequestPurpose
    public let hasTools: Bool
    /// Number of completed assistant/tool rounds already present in this
    /// request. Zero identifies the initial generation round of a turn.
    public let completedToolRounds: Int
    /// How the round before this one went; `nil` on a turn's first round.
    public let lastToolRound: ToolRoundOutcome?

    public init(
        model: String,
        purpose: ModelRequestPurpose,
        hasTools: Bool,
        completedToolRounds: Int,
        lastToolRound: ToolRoundOutcome? = nil
    ) {
        self.model = model
        self.purpose = purpose
        self.hasTools = hasTools
        self.completedToolRounds = completedToolRounds
        self.lastToolRound = lastToolRound
    }
}

/// Host policy for request-scoped reasoning controls. The default policy is
/// to leave every provider's configured behavior unchanged.
public typealias ModelReasoningPolicy =
    @Sendable (_ context: ModelReasoningContext) -> ModelReasoningOverride

/// Exact-token-counting capability of a model endpoint. Unsupported counting
/// is represented as domain data; once a counter is available, failure to use
/// it remains an error rather than being encoded as another optional value.
public enum TokenCounting: Sendable {
    case unavailable
    case available(
        @Sendable (_ entries: [Transcript.Entry], _ tools: [ToolDefinition])
            async throws(AgentRuntimeError) -> Int
    )
}

/// Complete input for one model request. The typed value remains available to
/// adapters that need it, while the transcript is the canonical model-facing
/// context. Provider-specific side data stays in this request value instead
/// of becoming another endpoint protocol.
public struct ModelRequest<Input: Sendable>: Sendable {
    public let input: Input
    public let entries: [Transcript.Entry]
    public let reasoning: ModelReasoningOverride

    public init(
        input: Input,
        entries: [Transcript.Entry],
        reasoning: ModelReasoningOverride = .providerDefault
    ) {
        self.input = input
        self.entries = entries
        self.reasoning = reasoning
    }
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
        request: ModelRequest<Input>,
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
        case .modelRequestFailed:
            "The model request failed. Please try again."
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
        case .invalidHistory(let invalid):
            "Invalid history event: \(invalid)"
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
