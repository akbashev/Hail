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

/// Events emitted by a model during a streaming turn.
public enum ModelEvent<Output: AgentOutput>: Sendable {
    /// A plain-text fragment from the model. Used for chat-style streaming.
    case text(String)

    /// A low-volume thought/trace fragment that should not be forwarded to the
    /// UI or logged at `info`.
    case thinking(String)

    /// A high-level status update, e.g. "Calling a tool." or "Generating...".
    case status(String)

    /// A request to execute one or more tools. The caller executes the tool and
    /// feeds the result back into the next turn.
    case toolCall(ToolCall)

    /// A partial structured value as it is being generated. Providers that
    /// support native structured streaming yield these while the response is
    /// still incomplete.
    case partialUpdated(Output.PartiallyGenerated)

    /// Token consumption for the request, when the endpoint can report it.
    case usage(ModelUsage)

    /// Current context occupancy, when the endpoint can report it.
    case contextUsage(ContextUsage)

    /// The final generated result of the turn. For chat this is a plain string;
    /// for structured turns it is the typed response.
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

/// Exact-token-counting capability of a model endpoint. Unsupported counting
/// is represented as domain data; once a counter is available, failure to use
/// it remains an error rather than being encoded as another optional value.
public enum TokenCounting: Sendable {
    case unavailable
    case available(
        @Sendable (_ messages: [LLMMessage], _ tools: [LLMToolSchema]) async throws(AgentRuntimeError) -> Int
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

    /// Streams one model turn for the given conversation context and tools.
    ///
    /// The stream yields intermediate events (text, thinking, status, tool calls)
    /// and terminates with exactly one of `.generated(String)` or `.failed(...)`.
    /// The caller executes any tool calls, appends the results to `messages`, and
    /// invokes `stream` again for the next turn.
    func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>>

    /// Streams one structured model turn, decoding the final response as `T`.
    ///
    /// Providers that support native structured output (OpenAI, Anthropic,
    /// Gemini, Ollama, etc. through AnyLanguageModel) use their schema mechanism.
    /// The local `kimi-code` endpoint uses a dedicated tool call as structured
    /// output. The stream terminates with exactly one of `.generated(T)` or `.failed(...)`.
    func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>>
}

// MARK: - Default structured fallback

extension ModelEndpoint {
    public var effectiveContextWindow: Int? { nil }

    public var tokenCounting: TokenCounting { .unavailable }

    /// Default implementation for endpoints that do not provide native structured
    /// output: stream the text form and attempt to decode the final string as JSON
    /// matching `T`.
    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                for await event in stream(messages: messages, tools: tools) {
                    switch event {
                    case .text(let text):
                        continuation.yield(.text(text))
                    case .thinking(let text):
                        continuation.yield(.thinking(text))
                    case .status(let message):
                        continuation.yield(.status(message))
                    case .toolCall(let call):
                        continuation.yield(.toolCall(call))
                    case .usage, .contextUsage:
                        break
                    case .partialUpdated(let partial):
                        guard let value = partial as? T.PartiallyGenerated else { break }
                        continuation.yield(.partialUpdated(value))
                    case .generated(let text):
                        if let value = text as? T {
                            continuation.yield(.generated(value))
                        } else {
                            do {
                                let content = try GeneratedContent(json: text)
                                let decoded = try T(content)
                                continuation.yield(.generated(decoded))
                            } catch {
                                continuation.yield(.failed(ModelEndpointError.decodingError(String(describing: error))))
                            }
                        }
                    case .failed(let error):
                        continuation.yield(.failed(error))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum ModelEndpointError: Error, Sendable, Equatable {
    case configuration(String)
    case authentication
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
