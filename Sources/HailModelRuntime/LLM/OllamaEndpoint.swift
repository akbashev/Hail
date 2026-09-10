import AnyLanguageModel
import AsyncHTTPClient
import HailCore
import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct OllamaHTTPResponse: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
}

typealias OllamaTransport = @Sendable (Data) async throws -> OllamaHTTPResponse

/// A small native Ollama `/api/chat` endpoint.
///
/// AnyLanguageModel remains the default abstraction for providers whose
/// response metadata is sufficient. Ollama is kept native because its final
/// streaming frame contains authoritative prompt/evaluation counts that the
/// generic response type currently discards.
public struct OllamaEndpoint: ModelEndpoint {
    public let model: String
    public let contextOwnership: ModelContextOwnership = .runtime
    public let effectiveContextWindow: Int?
    public let tokenCounting: TokenCounting

    private let temperature: Double
    private let numContext: Int?
    /// Ollama's `think` switch for reasoning-capable models. `nil` leaves the
    /// model's default untouched; `false` requests non-thinking generation.
    private let think: Bool?
    private let transport: OllamaTransport

    public init(
        model: String,
        baseURL: URL,
        temperature: Double,
        numContext: Int? = nil,
        think: Bool? = nil,
        requestTimeout: TimeInterval = 3_600,
        countTokens: (@Sendable ([LLMMessage], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        countInputTokens: (@Sendable (ModelInput, [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            temperature: temperature,
            numContext: numContext,
            think: think,
            countTokens: countTokens,
            countInputTokens: countInputTokens,
            transport: Self.makeTransport(
                baseURL: baseURL.appendingPathComponent("api/chat"),
                requestTimeout: requestTimeout
            )
        )
    }

    init(
        model: String,
        baseURL: URL,
        temperature: Double,
        numContext: Int? = nil,
        think: Bool? = nil,
        countTokens: (@Sendable ([LLMMessage], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        countInputTokens: (@Sendable (ModelInput, [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        transport: @escaping OllamaTransport
    ) {
        self.model = model
        self.temperature = temperature
        self.numContext = numContext
        self.think = think
        self.transport = transport
        self.effectiveContextWindow = numContext
        if let countInputTokens {
            self.tokenCounting = .availableInput(countInputTokens)
        } else {
            self.tokenCounting = countTokens.map(TokenCounting.available) ?? .unavailable
        }
    }

    public func stream(
        input: ModelInput,
        tools: [ToolDefinition]?
    ) -> AsyncStream<ModelEvent<String>> {
        stream(input: input, tools: tools, purpose: .generation)
    }

    public func stream(
        input: ModelInput,
        tools: [ToolDefinition]?,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<String>> {
        streamRaw(input: input, tools: tools, purpose: purpose)
    }

    /// Uses Ollama's portable text/report-tool contract rather than assuming
    /// that the selected Ollama runner implements native JSON-schema constraints.
    public func stream<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        streamContract(
            input: input,
            tools: tools,
            responseType: T.self
        )
    }

    private func streamContract<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        let reportTool: (name: String, schema: ToolDefinition)?
        switch T.outputContract {
        case .plainText:
            reportTool = nil
        case .reportTool(let name, let schema):
            reportTool = (name, schema)
        }

        let requestTools: [ToolDefinition]?
        if let reportTool {
            var result = tools ?? []
            if !result.contains(where: { $0.name == reportTool.name }) {
                result.append(reportTool.schema)
            }
            requestTools = result
        } else {
            requestTools = tools
        }

        return AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                var sawToolCall = false
                var completed = false

                for await event in self.streamRaw(
                    input: input,
                    tools: requestTools,
                    purpose: .generation
                ) {
                    switch event {
                    case .text(let text):
                        continuation.yield(.text(text))
                    case .thinking(let text):
                        continuation.yield(.thinking(text))
                    case .status(let status):
                        continuation.yield(.status(status))
                    case .toolCall(let call):
                        sawToolCall = true
                        guard !completed else { continue }
                        if let reportTool, call.name == reportTool.name {
                            do {
                                let value = try T(GeneratedContent(json: call.arguments.json))
                                continuation.yield(.status("Outcome received."))
                                continuation.yield(.generated(value))
                                completed = true
                            } catch {
                                continuation.yield(
                                    .failed(
                                        .decodingError(
                                            "Ollama report tool \(reportTool.name) returned invalid output: \(error)"
                                        )))
                                completed = true
                            }
                        } else {
                            continuation.yield(.toolCall(call))
                        }
                    case .usage(let usage):
                        continuation.yield(.usage(usage))
                    case .contextUsage(let usage):
                        continuation.yield(.contextUsage(usage))
                    case .failed(let error):
                        guard !completed else { continue }
                        continuation.yield(.failed(error))
                        completed = true
                    case .partialUpdated:
                        break
                    case .generated(let text):
                        guard !completed else { continue }
                        if let reportTool {
                            continuation.yield(
                                .failed(
                                    .invalidResponse(
                                        "Ollama finished without calling \(reportTool.name)."
                                    )))
                        } else {
                            do {
                                let value = try Self.decodePlainText(text, as: T.self)
                                continuation.yield(.generated(value))
                            } catch {
                                continuation.yield(.failed(.decodingError(String(describing: error))))
                            }
                        }
                        completed = true
                    }
                }

                // A regular tool round intentionally has no terminal output;
                // the reasoning loop executes the calls and asks the model again.
                if !completed && !sawToolCall {
                    continuation.yield(.failed(.invalidResponse("Ollama returned no output")))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRaw(
        input: ModelInput,
        tools: [ToolDefinition]?,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<String>> {
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Generating..."))
                    let body = try Self.requestBody(
                        model: model,
                        input: input,
                        tools: tools ?? [],
                        temperature: temperature,
                        numContext: numContext,
                        numPredict: Self.compactionOutputLimit(for: purpose),
                        // Compaction is a bounded summarization operation, not
                        // an agent decision. Do not let a reasoning-capable
                        // model spend its normal hidden-token budget on it.
                        think: Self.thinkingSetting(for: purpose, configured: think)
                    )
                    let response = try await transport(body)
                    guard (200..<300).contains(response.statusCode) else {
                        var errorBody = ""
                        for try await line in response.lines {
                            errorBody += line
                        }
                        if Self.isContextLengthError(errorBody) {
                            throw ModelEndpointError.contextLengthExceeded
                        }
                        throw ModelEndpointError.requestFailed(
                            "Ollama HTTP \(response.statusCode): \(errorBody)"
                        )
                    }

                    var text = ""
                    var emittedToolCalls = Set<String>()
                    var sawDone = false
                    var doneReason: String?
                    for try await line in response.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)

                        if let error = chunk.error {
                            if Self.isContextLengthError(error) {
                                throw ModelEndpointError.contextLengthExceeded
                            }
                            throw ModelEndpointError.requestFailed("Ollama: \(error)")
                        }

                        if let thought = chunk.message?.thinking, !thought.isEmpty {
                            continuation.yield(.thinking(thought))
                        }

                        if let fragment = chunk.message?.content, !fragment.isEmpty {
                            text += fragment
                            continuation.yield(.text(fragment))
                        }

                        if let calls = chunk.message?.toolCalls {
                            for (index, call) in calls.enumerated() {
                                let id = call.id ?? "\(call.function.name)-\(index)"
                                guard emittedToolCalls.insert(id).inserted else { continue }
                                continuation.yield(
                                    .toolCall(
                                        ToolCall(
                                            id: id,
                                            name: call.function.name,
                                            arguments: ToolArguments(
                                                json: try Self.argumentsJSON(call.function.arguments))
                                        )))
                            }
                        }

                        if chunk.done == true, let usage = chunk.usage {
                            continuation.yield(.usage(usage))
                            if let limit = effectiveContextWindow, let used = usage.inputTokens {
                                continuation.yield(
                                    .contextUsage(
                                        ContextUsage(
                                            usedTokens: used,
                                            limitTokens: limit,
                                            source: .reported
                                        )))
                            }
                        }

                        if chunk.done == true {
                            sawDone = true
                            doneReason = chunk.doneReason
                            break
                        }
                    }

                    // A tool-call response is continued by Hail's tool loop;
                    // only plain responses terminate the turn with output.
                    if emittedToolCalls.isEmpty {
                        if !sawDone {
                            // The HTTP body ended without Ollama's terminal
                            // chunk: the connection died mid-generation and
                            // the accumulated text is a partial response.
                            continuation.yield(
                                .failed(
                                    .requestFailed(
                                        "Ollama stream ended before reporting completion"
                                    )))
                        } else if let doneReason, doneReason != "stop" {
                            // Ollama reports abnormal endings (for example
                            // "length") with a clean done chunk; delivering
                            // the partial text as a final answer would hide
                            // the truncation.
                            continuation.yield(
                                .failed(
                                    .requestFailed(
                                        "Ollama stopped before finishing (done_reason: \(doneReason))"
                                    )))
                        } else {
                            continuation.yield(.generated(text))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as HTTPClientError where Self.isUnavailable(error) {
                    continuation.yield(.failed(.unavailable))
                    continuation.finish()
                } catch let error as ModelEndpointError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isUnavailable(_ error: HTTPClientError) -> Bool {
        [
            .remoteConnectionClosed,
            .connectTimeout,
            .getConnectionFromPoolTimeout,
            .deadlineExceeded,
            .tlsHandshakeTimeout,
        ].contains(error)
    }

    private static let httpClient: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        // Ollama streams NDJSON while the model is thinking/generating. A
        // read timeout would turn a slow local model into a false failure.
        configuration.timeout = .init(connect: .seconds(10), read: nil)
        configuration.httpVersion = .http1Only
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }()

    private static func makeTransport(
        baseURL: URL,
        requestTimeout: TimeInterval
    ) -> OllamaTransport {
        precondition(
            requestTimeout.isFinite && requestTimeout > 0 && requestTimeout <= TimeInterval(Int64.max),
            "Ollama request timeout must be positive and fit in seconds"
        )
        let timeout = TimeAmount.seconds(Int64(requestTimeout.rounded(.up)))

        return { body in
            var request = HTTPClientRequest(url: baseURL.absoluteString)
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.headers.add(name: "Accept", value: "application/x-ndjson")
            request.body = .bytes(ByteBuffer(bytes: body))

            let response = try await Self.httpClient.execute(request, timeout: timeout)
            return OllamaHTTPResponse(
                statusCode: Int(response.status.code),
                lines: Self.lines(from: response.body)
            )
        }
    }

    private static func lines(
        from body: HTTPClientResponse.Body
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pending = Data()
                    for try await buffer in body {
                        pending.append(contentsOf: buffer.readableBytesView)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = Data(pending[..<newline])
                            pending.removeSubrange(...newline)
                            let string = String(decoding: line, as: UTF8.self)
                            continuation.yield(
                                string.hasSuffix("\r") ? String(string.dropLast()) : string
                            )
                        }
                    }
                    if !pending.isEmpty {
                        continuation.yield(String(decoding: pending, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func compactionOutputLimit(
        for purpose: ModelRequestPurpose
    ) -> Int? {
        guard case .compaction(let maxOutputTokens) = purpose else { return nil }
        return max(1, maxOutputTokens)
    }

    private static func thinkingSetting(
        for purpose: ModelRequestPurpose,
        configured: Bool?
    ) -> Bool? {
        guard case .compaction = purpose else { return configured }
        return false
    }

    private static func requestBody(
        model: String,
        input: ModelInput,
        tools: [ToolDefinition],
        temperature: Double,
        numContext: Int?,
        numPredict: Int?,
        think: Bool?
    ) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: try input.entries.map(RequestMessage.init),
            tools: tools.isEmpty ? nil : try tools.map(RequestTool.init),
            options: RequestOptions(
                temperature: temperature,
                numContext: numContext,
                numPredict: numPredict
            ),
            stream: true,
            think: think
        )
        let encoder = JSONEncoder()
        // Tool schemas contain dictionaries for object properties. Stable
        // JSON is part of the provider request here: Ollama's prompt cache
        // sees the rendered tool definition, so dictionary iteration order
        // must not invalidate an otherwise identical prefix.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    private static func decodePlainText<T: AgentOutput>(_ text: String, as type: T.Type) throws -> T {
        if let value = text as? T {
            return value
        }
        return try T(GeneratedContent(kind: .string(text)))
    }

    private static func isContextLengthError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("context length")
            || normalized.contains("context window")
            || normalized.contains("prompt is too long")
            || normalized.contains("input is too long")
            || normalized.contains("maximum context")
    }

    private static func argumentsJSON(_ value: AnyCodableValue?) throws -> String {
        guard let value else {
            throw ModelEndpointError.invalidResponse("Ollama returned a tool call without arguments")
        }
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ModelEndpointError.invalidResponse("Ollama returned non-UTF8 tool arguments")
        }
        return json
    }
}

private struct ChatRequest: Encodable, Sendable {
    let model: String
    let messages: [RequestMessage]
    let tools: [RequestTool]?
    let options: RequestOptions
    let stream: Bool
    let think: Bool?
}

private struct RequestMessage: Encodable, Sendable {
    let role: String
    let content: String
    let thinking: String?
    let name: String?
    let toolName: String?
    let toolCalls: [RequestToolCall]?
    let toolCallID: String?
    let images: [String]?

    init(_ entry: ModelInput.Entry) throws {
        switch entry {
        case .message(let message):
            self.role = message.role.rawValue
            self.content = message.content
            self.thinking = message.thinking
            self.name = message.name
            self.toolName = nil
            self.toolCalls = try message.toolCalls?.map { try RequestToolCall($0) }
            self.toolCallID = message.toolCallID
            self.images = nil

        case .toolOutput(let callID, let name, let output):
            self.role = LLMMessage.Role.tool.rawValue
            self.thinking = nil
            self.name = nil
            self.toolName = name
            self.toolCalls = nil
            self.toolCallID = callID
            switch output {
            case .text(let text):
                self.content = text
                self.images = nil
            case .data(let data):
                let contentType = data.normalizedContentType
                if data.isTextLike {
                    self.content = String(decoding: data.body, as: UTF8.self)
                    self.images = nil
                } else if contentType.hasPrefix("image/") {
                    self.content = output.transcript
                    self.images = [data.body.base64EncodedString()]
                } else {
                    throw ModelEndpointError.invalidRequest(
                        "Ollama cannot map tool data with content type \(contentType); the provider adapter does not support this media type."
                    )
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, thinking, name
        case toolName = "tool_name"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case images
    }
}

private struct RequestToolCall: Encodable, Sendable {
    let id: String
    let type: String
    let function: RequestFunctionCall

    init(_ call: LLMToolCall) throws {
        self.id = call.id
        self.type = call.type
        self.function = try RequestFunctionCall(call.function)
    }
}

private struct RequestFunctionCall: Encodable, Sendable {
    let name: String
    let arguments: AnyCodableValue

    init(_ call: LLMToolCall.FunctionCall) throws {
        self.name = call.name
        guard let data = call.arguments.data(using: .utf8) else {
            throw ModelEndpointError.invalidRequest("Tool \(call.name) returned non-UTF8 arguments")
        }
        do {
            self.arguments = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        } catch {
            throw ModelEndpointError.invalidRequest(
                "Tool \(call.name) returned invalid JSON arguments: \(error)"
            )
        }
    }
}

private struct RequestTool: Encodable, Sendable {
    let type: String
    private let function: Function

    private struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: AnyCodableValue
    }

    init(_ tool: ToolDefinition) throws {
        self.type = "function"
        self.function = Function(
            name: tool.name,
            description: tool.description,
            parameters: try OllamaToolSchema.parameters(from: tool.parameters)
        )
    }
}

/// Adapts the canonical schema to Ollama's tool-call parser contract.
///
/// Ollama's Qwen-compatible parser determines the type of an XML parameter
/// from the function's direct root `properties`. It does not resolve a root
/// `$ref`/`anyOf` before doing that lookup. We therefore inline references and
/// expose the union of object properties at the root. Hail still decodes the
/// returned arguments against the original typed schema, so this adaptation
/// only affects provider guidance and never weakens execution validation.
private enum OllamaToolSchema {
    static func parameters(from schema: GenerationSchema) throws -> AnyCodableValue {
        let data = try JSONEncoder().encode(schema)
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .object(let root) = value else {
            throw ModelEndpointError.invalidRequest("Ollama tool parameters must be an object schema")
        }

        let definitions: [String: AnyCodableValue]
        if case .object(let defs) = root["$defs"] {
            definitions = defs
        } else {
            definitions = [:]
        }

        let rootNode = resolve(.object(root), definitions: definitions)
        guard case .object(let resolvedRoot) = rootNode else {
            throw ModelEndpointError.invalidRequest(
                "Ollama tool parameters must resolve to an object schema"
            )
        }
        let normalized = try normalizeRoot(resolvedRoot, definitions: definitions)
        guard !containsUnresolvedReference(normalized, definitions: definitions) else {
            throw ModelEndpointError.invalidRequest(
                "Ollama tool schema contains an unresolved reference"
            )
        }
        return normalized
    }

    private static func resolve(
        _ value: AnyCodableValue,
        definitions: [String: AnyCodableValue]
    ) -> AnyCodableValue {
        guard case .object(let object) = value,
            case .string(let reference)? = object["$ref"],
            let name = reference.split(separator: "/").last.map(String.init),
            let definition = definitions[name]
        else {
            return value
        }
        return resolve(definition, definitions: definitions)
    }

    private static func normalizeRoot(
        _ object: [String: AnyCodableValue],
        definitions: [String: AnyCodableValue]
    ) throws -> AnyCodableValue {
        if object["anyOf"] != nil {
            throw ModelEndpointError.invalidRequest(
                "Ollama tool parameters cannot use a root union; expose each variant as a separate tool"
            )
        }
        return normalizeObject(object, definitions: definitions)
    }

    private static func normalizeObject(
        _ object: [String: AnyCodableValue],
        definitions: [String: AnyCodableValue]
    ) -> AnyCodableValue {
        var result = object.filter { $0.key != "$defs" && $0.key != "$ref" }
        if case .object(let properties)? = object["properties"] {
            result["properties"] = .object(
                properties.mapValues { normalize($0, definitions: definitions) }
            )
        }
        if let items = object["items"] {
            result["items"] = normalize(items, definitions: definitions)
        }
        return .object(result)
    }

    private static func normalize(
        _ value: AnyCodableValue,
        definitions: [String: AnyCodableValue]
    ) -> AnyCodableValue {
        let resolved = resolve(value, definitions: definitions)
        guard case .object(let object) = resolved else { return resolved }

        if case .array(let choices)? = object["anyOf"] {
            return .objectUnion(
                choices.map { normalize($0, definitions: definitions) }
            )
        }
        return normalizeObject(object, definitions: definitions)
    }

    private static func containsUnresolvedReference(
        _ value: AnyCodableValue,
        definitions: [String: AnyCodableValue]
    ) -> Bool {
        switch value {
        case .object(let object):
            if case .string(let reference)? = object["$ref"],
                let name = reference.split(separator: "/").last.map(String.init),
                definitions[name] == nil
            {
                return true
            }
            return object.values.contains {
                containsUnresolvedReference($0, definitions: definitions)
            }
        case .array(let values):
            return values.contains {
                containsUnresolvedReference($0, definitions: definitions)
            }
        case .string, .number, .bool, .null:
            return false
        }
    }
}

private struct RequestOptions: Encodable, Sendable {
    let temperature: Double
    let numContext: Int?
    let numPredict: Int?

    private enum CodingKeys: String, CodingKey {
        case temperature
        case numContext = "num_ctx"
        case numPredict = "num_predict"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(numContext, forKey: .numContext)
        try container.encodeIfPresent(numPredict, forKey: .numPredict)
    }
}

private struct ChatChunk: Decodable, Sendable {
    let message: ChunkMessage?
    let done: Bool?
    let doneReason: String?
    let error: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case message, done, error
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }

    var usage: ModelUsage? {
        guard promptEvalCount != nil || evalCount != nil else { return nil }
        let total: Int?
        if let promptEvalCount, let evalCount {
            total = promptEvalCount + evalCount
        } else {
            total = nil
        }
        return ModelUsage(
            inputTokens: promptEvalCount,
            outputTokens: evalCount,
            totalTokens: total,
            source: .reported
        )
    }
}

private struct ChunkMessage: Decodable, Sendable {
    let content: String?
    let thinking: String?
    let toolCalls: [ChunkToolCall]?

    private enum CodingKeys: String, CodingKey {
        case content, thinking
        case toolCalls = "tool_calls"
    }
}

private struct ChunkToolCall: Decodable, Sendable {
    let id: String?
    let function: ChunkFunction
}

private struct ChunkFunction: Decodable, Sendable {
    let name: String
    let arguments: AnyCodableValue?
}

/// A JSON value used only for preserving Ollama's arbitrary tool arguments.
private enum AnyCodableValue: Codable, Equatable, Sendable {
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func objectUnion(_ values: [AnyCodableValue]) -> AnyCodableValue {
        .object(["anyOf": .array(values)])
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: AnyCodableValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(AnyCodableValue.self, forKey: key)
            }
            self = .object(object)
        } else if var container = try? decoder.unkeyedContainer() {
            var values: [AnyCodableValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(AnyCodableValue.self))
            }
            self = .array(values)
        } else {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            try values.forEach { try container.encode($0) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
