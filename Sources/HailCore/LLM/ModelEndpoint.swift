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

    /// A partial generated value as it is being generated. Providers that
    /// support native streaming yield cumulative snapshots; plain-text typed
    /// streams may also emit these alongside their text deltas.
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
        @Sendable (_ messages: [LLMMessage], _ tools: [ToolDefinition]) async throws(AgentRuntimeError) -> Int
    )
    /// Provider-specific counting that can inspect the rich input before it is
    /// projected onto the provider wire format. This is the capability used
    /// when a tool returns an image, audio file, document, or other artifact.
    case availableInput(
        @Sendable (_ input: ModelInput, _ tools: [ToolDefinition]) async throws(AgentRuntimeError) -> Int
    )
}

/// The ordered, live input to one model request.
///
/// Conversation messages remain plain, durable values. A binary tool output is
/// represented by its own entry and exists only while Hail continues the
/// current reasoning turn. Its semantic `ToolResult` is journaled, but the
/// fetched body is not embedded in journal events or snapshots.
public struct ModelInput: Sendable {
    public enum Entry: Sendable {
        case message(LLMMessage)
        case toolOutput(callID: String, name: String, output: ToolOutput)
    }

    public private(set) var entries: [Entry]

    public init(messages: [LLMMessage]) {
        self.entries = messages.map(Entry.message)
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public mutating func append(_ message: LLMMessage) {
        entries.append(.message(message))
    }

    public mutating func appendToolOutput(
        callID: String,
        name: String,
        output: ToolOutput
    ) {
        entries.append(.toolOutput(callID: callID, name: name, output: output))
    }

    /// Plain semantic projection used for persistence, compaction and
    /// text-only endpoints. Binary tool bodies are reduced to metadata.
    public var messages: [LLMMessage] {
        entries.map { entry in
            switch entry {
            case .message(let message):
                return message
            case .toolOutput(let callID, _, let output):
                let content: String
                switch output {
                case .text(let text):
                    content = text
                case .data(let data) where data.isTextLike:
                    content = String(decoding: data.body, as: UTF8.self)
                case .data:
                    content = output.transcript
                }
                return LLMMessage(
                    role: .tool,
                    content: content,
                    toolCallID: callID
                )
            }
        }
    }

    /// Semantic messages for rich outputs produced during the live reasoning
    /// turn. These can be attached to a rebuilt durable request when the
    /// compactor has not retained their metadata message.
    public var richOutputMessages: [LLMMessage] {
        entries.compactMap { entry in
            guard case .toolOutput(let callID, _, let output) = entry else { return nil }
            let content: String
            switch output {
            case .text(let text):
                content = text
            case .data(let data) where data.isTextLike:
                content = String(decoding: data.body, as: UTF8.self)
            case .data:
                content = output.transcript
            }
            return LLMMessage(role: .tool, content: content, toolCallID: callID)
        }
    }

    public var containsData: Bool {
        entries.contains { entry in
            guard case .toolOutput(_, _, .data) = entry else { return false }
            return true
        }
    }

    public var containsUnsupportedData: Bool {
        entries.contains { entry in
            guard case .toolOutput(_, _, .data(let data)) = entry else { return false }
            return !data.isTextLike
        }
    }

    /// Projects this request for an endpoint that cannot consume rich tool
    /// output. It fails explicitly instead of pretending resource metadata is
    /// the fetched content.
    public func textMessages(for model: String) throws(ModelEndpointError) -> [LLMMessage] {
        guard !containsUnsupportedData else {
            throw .invalidRequest(
                "Model endpoint \(model) cannot consume the data returned by this tool."
            )
        }
        return messages
    }

    /// Rebuilds compacted context while retaining matching live tool outputs.
    public func rebased(on messages: [LLMMessage]) -> ModelInput {
        var outputs: [String: [Entry]] = [:]
        for entry in entries {
            guard case .toolOutput(let callID, _, _) = entry else { continue }
            outputs[callID, default: []].append(entry)
        }
        var outputIndices: [String: Int] = [:]
        return ModelInput(
            entries: messages.map { message in
                guard message.role == .tool,
                    let callID = message.toolCallID,
                    let matchingOutputs = outputs[callID]
                else {
                    return .message(message)
                }
                let index = outputIndices[callID, default: 0]
                guard matchingOutputs.indices.contains(index) else {
                    return .message(message)
                }
                outputIndices[callID] = index + 1
                return matchingOutputs[index]
            }
        )
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

    /// Streams one model turn for the given conversation context and tools.
    ///
    /// The stream yields intermediate events (text, thinking, status, tool calls)
    /// and terminates with exactly one of `.generated(String)` or `.failed(...)`.
    /// The caller executes any tool calls, appends the results to `messages`, and
    /// invokes `stream` again for the next turn.
    func stream(
        input: ModelInput,
        tools: [ToolDefinition]?
    ) -> AsyncStream<ModelEvent<String>>

    /// Streams a plain-text request with an explicit semantic purpose.
    /// Compaction requests are separate so a provider can bound summarizer
    /// output without silently changing ordinary generation limits.
    func stream(
        input: ModelInput,
        tools: [ToolDefinition]?,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<String>>

    /// Streams one structured model turn, decoding the final response as `T`.
    ///
    /// Providers with native structured output may use their schema mechanism.
    /// Providers without it may use the portable report-tool contract. The
    /// stream terminates with exactly one of `.generated(T)` or `.failed(...)`.
    func stream<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>>
}

// MARK: - Default structured fallback

extension ModelEndpoint {
    public var effectiveContextWindow: Int? { nil }

    public var tokenCounting: TokenCounting { .unavailable }

    public func stream(
        input: ModelInput,
        tools: [ToolDefinition]?,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<String>> {
        stream(input: input, tools: tools)
    }

    /// Default implementation for endpoints that do not provide native structured
    /// output: stream the text form and attempt to decode the final string as JSON
    /// matching `T`.
    public func stream<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                for await event in stream(input: input, tools: tools) {
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
