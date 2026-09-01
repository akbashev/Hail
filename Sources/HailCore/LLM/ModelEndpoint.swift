import AnyLanguageModel

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

public protocol ModelEndpoint: Sendable {
    var model: String { get }
    var contextOwnership: ModelContextOwnership { get }

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
