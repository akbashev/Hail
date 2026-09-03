import AnyLanguageModel
import Foundation
import HailCore

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

    private let baseURL: URL
    private let temperature: Double
    private let numContext: Int?
    private let session: URLSession

    public init(
        model: String,
        baseURL: URL,
        temperature: Double,
        numContext: Int? = nil,
        countTokens: (@Sendable ([LLMMessage], [LLMToolSchema]) async throws -> Int)? = nil,
        session: URLSession = .shared
    ) {
        self.model = model
        self.baseURL = baseURL.appendingPathComponent("api/chat")
        self.temperature = temperature
        self.numContext = numContext
        self.session = session
        self.effectiveContextWindow = numContext
        self.tokenCounting = countTokens.map(TokenCounting.available) ?? .unavailable
    }

    public func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>> {
        streamRaw(messages: messages, tools: tools, format: nil)
    }

    /// Native structured-output support for plain-text contracts such as
    /// `ChatResponse`. The generic fallback still decodes the final JSON, but
    /// supplying Ollama's `format` schema makes that response deterministic.
    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        return AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                let format: AnyCodableValue?
                do {
                    format = T.self == String.self ? nil : try Self.generationFormat(for: T.self)
                } catch {
                    continuation.yield(.failed(.decodingError("Unable to encode Ollama response schema: \(error)")))
                    continuation.finish()
                    return
                }
                for await event in self.streamRaw(messages: messages, tools: tools, format: format) {
                    switch event {
                    case .text(let text): continuation.yield(.text(text))
                    case .thinking(let text): continuation.yield(.thinking(text))
                    case .status(let status): continuation.yield(.status(status))
                    case .toolCall(let call): continuation.yield(.toolCall(call))
                    case .usage(let usage): continuation.yield(.usage(usage))
                    case .contextUsage(let usage): continuation.yield(.contextUsage(usage))
                    case .failed(let error): continuation.yield(.failed(error))
                    case .partialUpdated: break
                    case .generated(let text):
                        if let value = text as? T {
                            continuation.yield(.generated(value))
                        } else {
                            do {
                                let value = try T(GeneratedContent(json: text))
                                continuation.yield(.generated(value))
                            } catch {
                                continuation.yield(.failed(.decodingError(String(describing: error))))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRaw(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        format: AnyCodableValue?
    ) -> AsyncStream<ModelEvent<String>> {
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Generating..."))
                    let body = try Self.requestBody(
                        model: model,
                        messages: messages,
                        tools: tools ?? [],
                        temperature: temperature,
                        numContext: numContext,
                        format: format
                    )
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                    request.httpBody = body

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ModelEndpointError.invalidResponse("Ollama returned no HTTP response")
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        throw ModelEndpointError.requestFailed(
                            "Ollama HTTP \(httpResponse.statusCode): \(errorBody)"
                        )
                    }

                    var text = ""
                    var emittedToolCalls = Set<String>()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)

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

                        if chunk.done, let usage = chunk.usage {
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

                        if chunk.done {
                            break
                        }
                    }

                    // A tool-call response is continued by Hail's tool loop;
                    // only plain responses terminate the turn with output.
                    if emittedToolCalls.isEmpty {
                        continuation.yield(.generated(text))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
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

    private static func requestBody(
        model: String,
        messages: [LLMMessage],
        tools: [LLMToolSchema],
        temperature: Double,
        numContext: Int?,
        format: AnyCodableValue?
    ) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: try messages.map { try RequestMessage($0) },
            tools: tools.isEmpty ? nil : tools.map(RequestTool.init),
            options: RequestOptions(temperature: temperature, numContext: numContext),
            format: format,
            stream: true
        )
        return try JSONEncoder().encode(request)
    }

    private static func generationFormat<T: AgentOutput>(for type: T.Type) throws -> AnyCodableValue {
        let data = try JSONEncoder().encode(type.generationSchema)
        return try JSONDecoder().decode(AnyCodableValue.self, from: data)
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
    let format: AnyCodableValue?
    let stream: Bool
}

private struct RequestMessage: Encodable, Sendable {
    let role: String
    let content: String
    let name: String?
    let toolCalls: [RequestToolCall]?
    let toolCallID: String?

    init(_ message: LLMMessage) throws {
        self.role = message.role.rawValue
        self.content = message.content
        self.name = message.name
        self.toolCalls = try message.toolCalls?.map { try RequestToolCall($0) }
        self.toolCallID = message.toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
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
    let function: LLMToolSchema.FunctionSchema

    init(_ tool: LLMToolSchema) {
        self.type = tool.type
        self.function = tool.function
    }
}

private struct RequestOptions: Encodable, Sendable {
    let temperature: Double
    let numContext: Int?

    private enum CodingKeys: String, CodingKey {
        case temperature
        case numContext = "num_ctx"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(numContext, forKey: .numContext)
    }
}

private struct ChatChunk: Decodable, Sendable {
    let message: ChunkMessage?
    let done: Bool
    let promptEvalCount: Int?
    let evalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case message, done
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
private enum AnyCodableValue: Codable, Sendable {
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

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
