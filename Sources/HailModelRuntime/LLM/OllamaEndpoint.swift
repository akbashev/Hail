import AnyLanguageModel
import AsyncHTTPClient
import HailCore
import NIOCore
import PartialJSONDecoder

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

private enum OllamaEvent: Sendable {
    case activity(ModelActivity)
    case toolsRequested(ModelToolRound)
    case usage(ModelUsage)
    case contextUsage(ContextUsage)
    case generated(GeneratedContent)
    case failed(ModelEndpointError)
}

/// Pure state machine for Ollama's NDJSON response. HTTP reading stays in
/// `streamRaw`; this value owns all provider-response decisions and is easy to
/// exercise with decoded chunks without starting a server.
private struct OllamaStreamState: Sendable {
    let text: String
    let toolCalls: [ToolCall]
    let emittedToolCallIDs: Set<String>
    let narration: [Transcript.Segment]
    let reasoning: [Transcript.Segment]
    let sawDone: Bool
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    init(
        text: String = "",
        toolCalls: [ToolCall] = [],
        emittedToolCallIDs: Set<String> = [],
        narration: [Transcript.Segment] = [],
        reasoning: [Transcript.Segment] = [],
        sawDone: Bool = false,
        doneReason: String? = nil,
        promptEvalCount: Int? = nil,
        evalCount: Int? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.emittedToolCallIDs = emittedToolCallIDs
        self.narration = narration
        self.reasoning = reasoning
        self.sawDone = sawDone
        self.doneReason = doneReason
        self.promptEvalCount = promptEvalCount
        self.evalCount = evalCount
    }

    func applying(
        _ chunk: ChatChunk,
        contextWindow: Int?
    ) throws -> (state: Self, events: [OllamaEvent]) {
        if let error = chunk.error {
            if OllamaEndpoint.isContextLengthError(error) {
                throw ModelEndpointError.contextLengthExceeded
            }
            throw ModelEndpointError.requestFailed("Ollama: \(error)")
        }

        var next = self
        var events: [OllamaEvent] = []
        if let thought = chunk.message?.thinking, !thought.isEmpty {
            next = Self(
                text: next.text,
                toolCalls: next.toolCalls,
                emittedToolCallIDs: next.emittedToolCallIDs,
                narration: next.narration,
                reasoning: next.reasoning + [.text(.init(content: thought))],
                sawDone: next.sawDone,
                doneReason: next.doneReason,
                promptEvalCount: next.promptEvalCount,
                evalCount: next.evalCount
            )
            events.append(.activity(.reasoningDelta(GeneratedContent(thought))))
        }
        if let fragment = chunk.message?.content, !fragment.isEmpty {
            // Coalesce consecutive text fragments into one segment, matching
            // how `text` accumulates. Per-chunk segments would render as
            // word-per-line when a transcript entry is rebuilt for a later
            // request, and models reliably mimic that formatting.
            var narration = next.narration
            if case .text(let last)? = narration.last {
                narration[narration.count - 1] = .text(.init(content: last.content + fragment))
            } else {
                narration.append(.text(.init(content: fragment)))
            }
            next = Self(
                text: next.text + fragment,
                toolCalls: next.toolCalls,
                emittedToolCallIDs: next.emittedToolCallIDs,
                narration: narration,
                reasoning: next.reasoning,
                sawDone: next.sawDone,
                doneReason: next.doneReason,
                promptEvalCount: next.promptEvalCount,
                evalCount: next.evalCount
            )
            events.append(.activity(.narrationDelta(GeneratedContent(fragment))))
        }
        if let calls = chunk.message?.toolCalls {
            for (index, call) in calls.enumerated() {
                let id = call.id ?? "\(call.function.name)-\(index)"
                guard !next.emittedToolCallIDs.contains(id) else { continue }
                let toolCall = ToolCall(
                    id: id,
                    name: call.function.name,
                    arguments: try GeneratedContent(
                        json: OllamaEndpoint.argumentsJSON(call.function.arguments)
                    )
                )
                next = Self(
                    text: next.text,
                    toolCalls: next.toolCalls + [toolCall],
                    emittedToolCallIDs: next.emittedToolCallIDs.union([id]),
                    narration: next.narration,
                    reasoning: next.reasoning,
                    sawDone: next.sawDone,
                    doneReason: next.doneReason,
                    promptEvalCount: next.promptEvalCount,
                    evalCount: next.evalCount
                )
            }
        }
        if chunk.done == true {
            next = Self(
                text: next.text,
                toolCalls: next.toolCalls,
                emittedToolCallIDs: next.emittedToolCallIDs,
                narration: next.narration,
                reasoning: next.reasoning,
                sawDone: true,
                doneReason: chunk.doneReason,
                promptEvalCount: chunk.promptEvalCount ?? next.promptEvalCount,
                evalCount: chunk.evalCount ?? next.evalCount
            )
            if let usage = chunk.usage {
                events.append(.usage(usage))
                if let limit = contextWindow,
                    let used = usage.inputTokens
                {
                    events.append(
                        .contextUsage(
                            ContextUsage(
                                usedTokens: used,
                                limitTokens: limit,
                                source: .reported
                            )
                        )
                    )
                }
            }
        }
        return (next, events)
    }

    func finishing(
        format: AnyCodableValue?,
        contextWindow: Int?,
        purpose: ModelRequestPurpose
    ) throws -> [OllamaEvent] {
        if let doneReason, doneReason == "length",
            Self.consumedContextFillsWindow(
                promptTokens: promptEvalCount,
                generatedTokens: evalCount,
                contextWindow: contextWindow
            )
        {
            // Ollama reports a context-exhausted generation as done_reason
            // "length": it silently truncates input that exceeds num_ctx and
            // stops as soon as the prompt leaves no generation room. Surface
            // the typed overflow so the runtime's context recovery runs
            // instead of failing the turn as generic model misbehavior.
            return [.failed(.contextLengthExceeded)]
        }
        if let doneReason, doneReason == "length",
            case .compaction = purpose,
            !text.isEmpty
        {
            // The summarizer was invited to emit at most num_predict tokens
            // and reached that cap with window headroom left: a truncated
            // report, not misbehavior. Complete the JSON at its last whole
            // value and use the salvaged prefix; the host's context
            // projection fits it deterministically from here.
            if let completed = try? JSONCompleter().complete(text),
                let salvaged = try? GeneratedContent(json: completed)
            {
                return [.generated(salvaged)]
            }
        }
        if !toolCalls.isEmpty {
            let narration =
                narration.isEmpty
                ? nil
                : Transcript.Response(assetIDs: [], segments: narration)
            return [
                .toolsRequested(
                    ModelToolRound(
                        narration: narration,
                        reasoning: reasoning,
                        calls: toolCalls
                    )
                )
            ]
        }
        guard sawDone else {
            return [.failed(.requestFailed("Ollama stream ended before reporting completion"))]
        }
        if let doneReason, doneReason != "stop" {
            return [
                .failed(
                    .requestFailed(
                        "Ollama stopped before finishing (done_reason: \(doneReason))"
                    )
                )
            ]
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.failed(.invalidResponse("Ollama completed without visible output or tool calls"))]
        }
        let generated =
            format == nil
            ? GeneratedContent(text)
            : try GeneratedContent(json: text)
        return [.generated(generated)]
    }

    /// A "length" finish means context exhaustion only when the prompt and
    /// generation together consumed the window. An output cap with headroom
    /// left (for example a Modelfile `num_predict`, or Hail's own compaction
    /// summarizer cap) is a plain failed request, not an overflow.
    private static func consumedContextFillsWindow(
        promptTokens: Int?,
        generatedTokens: Int?,
        contextWindow: Int?
    ) -> Bool {
        guard let contextWindow else { return true }
        guard promptTokens != nil || generatedTokens != nil else { return true }
        return (promptTokens ?? 0) + (generatedTokens ?? 0) >= contextWindow
    }
}

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
        countTokens: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            temperature: temperature,
            numContext: numContext,
            think: think,
            countTokens: countTokens,
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
        countTokens: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        transport: @escaping OllamaTransport
    ) {
        self.model = model
        self.temperature = temperature
        self.numContext = numContext
        self.think = think
        self.transport = transport
        self.effectiveContextWindow = numContext
        self.tokenCounting = countTokens.map(TokenCounting.available) ?? .unavailable
    }

    /// Requests the declared generated value directly. Plain text uses
    /// Ollama's normal content field; structured values use Ollama's native
    /// JSON-schema `format` field.
    public func stream<Input, Output>(
        input: Input,
        entries: [Transcript.Entry],
        tools: [AnyTool],
        authority: any Authority,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable
    {
        stream(
            request: ModelRequest(input: input, entries: entries),
            tools: tools,
            authority: authority,
            generating: outputType,
            purpose: purpose
        )
    }

    public func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable
    {
        streamContract(
            entries: request.entries,
            reasoningRounds: request.reasoningRounds,
            tools: tools.map(\.schema),
            generating: outputType,
            purpose: purpose
        )
    }

    private func streamContract<Output>(
        entries: [Transcript.Entry],
        reasoningRounds: [[Transcript.Segment]],
        tools: [ToolDefinition],
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        return AsyncStream(ModelEvent<Output>.self) { continuation in
            let task = Task {
                let outputFormat: AnyCodableValue?
                do {
                    outputFormat = Output.self == String.self ? nil : try Self.outputSchema(for: Output.self)
                } catch {
                    continuation.yield(.failed(.invalidRequest("Could not encode Ollama output schema: \(error)")))
                    continuation.finish()
                    return
                }
                var sawToolRound = false
                var completed = false

                for await event in self.streamRaw(
                    entries: entries,
                    reasoningRounds: reasoningRounds,
                    tools: tools,
                    purpose: purpose,
                    format: outputFormat
                ) {
                    switch event {
                    case .activity(let activity):
                        continuation.yield(.activity(activity))
                    case .toolsRequested(let round):
                        sawToolRound = true
                        guard !completed else { continue }
                        continuation.yield(.toolsRequested(round))
                    case .usage(let usage):
                        continuation.yield(.usage(usage))
                    case .contextUsage(let usage):
                        continuation.yield(.contextUsage(usage))
                    case .failed(let error):
                        guard !completed else { continue }
                        continuation.yield(.failed(error))
                        completed = true
                    case .generated(let content):
                        guard !completed else { continue }
                        do {
                            let value = try Self.decodeOutput(content.jsonString, as: Output.self)
                            continuation.yield(.generated(value))
                        } catch {
                            continuation.yield(.failed(.decodingError(String(describing: error))))
                        }
                        completed = true
                    }
                }

                // A regular tool round intentionally has no terminal output;
                // the reasoning loop executes the calls and asks the model again.
                if !completed && !sawToolRound {
                    continuation.yield(.failed(.invalidResponse("Ollama returned no output")))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRaw(
        entries: [Transcript.Entry],
        reasoningRounds: [[Transcript.Segment]],
        tools: [ToolDefinition]?,
        purpose: ModelRequestPurpose,
        format: AnyCodableValue? = nil
    ) -> AsyncStream<OllamaEvent> {
        AsyncStream(OllamaEvent.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.activity(.status(GeneratedContent("Generating..."))))
                    let body = try Self.requestBody(
                        model: model,
                        entries: entries,
                        reasoningRounds: reasoningRounds,
                        tools: tools ?? [],
                        temperature: temperature,
                        numContext: numContext,
                        numPredict: Self.compactionOutputLimit(for: purpose),
                        // Compaction is a bounded summarization operation, not
                        // an agent decision. Do not let a reasoning-capable
                        // model spend its normal hidden-token budget on it.
                        think: Self.thinkingSetting(for: purpose, configured: think),
                        format: format
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

                    var state = OllamaStreamState()
                    for try await line in response.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)

                        let reduction = try state.applying(
                            chunk,
                            contextWindow: effectiveContextWindow
                        )
                        state = reduction.state
                        for event in reduction.events {
                            continuation.yield(event)
                        }
                        if chunk.done == true {
                            break
                        }
                    }
                    for event in try state.finishing(
                        format: format,
                        contextWindow: effectiveContextWindow,
                        purpose: purpose
                    ) {
                        continuation.yield(event)
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
        entries: [Transcript.Entry],
        reasoningRounds: [[Transcript.Segment]],
        tools: [ToolDefinition],
        temperature: Double,
        numContext: Int?,
        numPredict: Int?,
        think: Bool?,
        format: AnyCodableValue?
    ) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: try RequestMessage.messages(
                from: entries,
                reasoningRounds: reasoningRounds
            ),
            tools: tools.isEmpty ? nil : try tools.map(RequestTool.init),
            format: format,
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

    private static func decodeOutput<T>(
        _ text: String,
        as type: T.Type
    ) throws -> T where T: Codable & Sendable & Generable {
        return try T(GeneratedContent(json: text))
    }

    /// Encodes the declared output type's generation schema for Ollama's
    /// `format` field. The schema is inlined first: Ollama's grammar builder
    /// resolves a `$ref` only at the document root and silently drops the
    /// constraint on inner references. Schemas that cannot be inlined
    /// (missing definitions, cycles) fail here as `invalidRequest` instead
    /// of reaching the provider unconstrained.
    private static func outputSchema<T>(for type: T.Type) throws -> AnyCodableValue
    where T: Codable & Sendable & Generable {
        let data = try JSONEncoder().encode(T.generationSchema)
        let schema = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        return try inlineSchemaRefs(schema)
    }

    /// Why a schema could not be inlined for Ollama's grammar builder. Every
    /// case is rejected loudly: sending the schema anyway would repeat the
    /// silent unconstrained-sampling failure this exists to prevent.
    enum SchemaInliningError: Error, Equatable {
        /// A `$ref` pointing outside the document's own `$defs`.
        case externalReference(String)
        /// A `$ref` whose definition is absent from the root `$defs`.
        case missingDefinition(String)
        /// Definitions that reference each other recursively; inlining them
        /// would never terminate.
        case referenceCycle([String])
    }

    /// Resolves every local `$ref` against the root `$defs` and returns a
    /// single self-contained schema. Ollama's grammar builder follows a `$ref`
    /// only at the document root; an inner reference makes it silently drop
    /// the constraint. Repeated definitions inline at each use site; the
    /// emitted `$defs` block is dropped once nothing references it.
    static func inlineSchemaRefs(_ schema: AnyCodableValue) throws -> AnyCodableValue {
        guard case .object(let root) = schema else { return schema }
        let defs: [String: AnyCodableValue]
        if case .object(let defsObject)? = root["$defs"] {
            defs = defsObject
        } else {
            defs = [:]
        }

        func resolving(
            _ value: AnyCodableValue,
            active: Set<String>
        ) throws -> AnyCodableValue {
            switch value {
            case .object(let object):
                if case .string(let pointer)? = object["$ref"] {
                    guard pointer.hasPrefix("#/$defs/") else {
                        throw SchemaInliningError.externalReference(pointer)
                    }
                    let key = String(pointer.dropFirst("#/$defs/".count))
                    guard let target = defs[key] else {
                        throw SchemaInliningError.missingDefinition(key)
                    }
                    var branch = active
                    guard branch.insert(key).inserted else {
                        throw SchemaInliningError.referenceCycle(active.sorted() + [key])
                    }
                    // Siblings of the $ref (e.g. an overriding description)
                    // win over the referenced definition's own keys.
                    var resolved = target
                    if object.count > 1, case .object(let targetObject) = target {
                        var siblings = object
                        siblings["$ref"] = nil
                        resolved = .object(targetObject.merging(siblings) { _, new in new })
                    }
                    return try resolving(resolved, active: branch)
                }
                return .object(try object.mapValues { try resolving($0, active: active) })
            case .array(let values):
                return .array(try values.map { try resolving($0, active: active) })
            default:
                return value
            }
        }

        var rootWithoutDefs = root
        rootWithoutDefs["$defs"] = nil
        return try resolving(.object(rootWithoutDefs), active: [])
    }

    static func isContextLengthError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("context length")
            || normalized.contains("context window")
            || normalized.contains("prompt is too long")
            || normalized.contains("input is too long")
            || normalized.contains("maximum context")
    }

    fileprivate static func argumentsJSON(_ value: AnyCodableValue?) throws -> String {
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
    let format: AnyCodableValue?
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

    /// Ollama expects an assistant tool round as one assistant message whose
    /// `tool_calls` accompany its content. Hail's provider-neutral transcript
    /// can represent those as adjacent response/tool-call entries, so merge
    /// that pair at this transport boundary.
    static func messages(
        from entries: [Transcript.Entry],
        reasoningRounds: [[Transcript.Segment]]
    ) throws -> [RequestMessage] {
        var messages: [RequestMessage] = []
        var index = 0
        var reasoningIndex = 0

        while index < entries.count {
            if case .response(let response) = entries[index],
                index + 1 < entries.count,
                case .toolCalls(let calls) = entries[index + 1]
            {
                let reasoning =
                    reasoningIndex < reasoningRounds.count
                    ? reasoningRounds[reasoningIndex]
                    : []
                reasoningIndex += 1
                messages.append(
                    try RequestMessage(
                        response: response,
                        toolCalls: calls,
                        reasoning: reasoning
                    )
                )
                index += 2
            } else if case .toolCalls(let calls) = entries[index] {
                let reasoning =
                    reasoningIndex < reasoningRounds.count
                    ? reasoningRounds[reasoningIndex]
                    : []
                reasoningIndex += 1
                messages.append(
                    try RequestMessage(
                        toolCalls: calls,
                        reasoning: reasoning
                    )
                )
                index += 1
            } else {
                messages.append(try RequestMessage(entries[index]))
                index += 1
            }
        }

        return messages
    }

    init(
        response: Transcript.Response,
        toolCalls: Transcript.ToolCalls,
        reasoning: [Transcript.Segment]
    ) throws {
        self.role = "assistant"
        self.content = Self.render(response.segments)
        self.thinking = Self.render(reasoning)
        self.name = nil
        self.toolName = nil
        self.toolCalls = try Self.decodeToolCalls(toolCalls)
        self.toolCallID = nil
        self.images = try Self.encodedImages(response.segments)
    }

    init(
        toolCalls: Transcript.ToolCalls,
        reasoning: [Transcript.Segment]
    ) throws {
        self.role = "assistant"
        self.content = ""
        self.thinking = Self.render(reasoning)
        self.name = nil
        self.toolName = nil
        self.toolCalls = try Self.decodeToolCalls(toolCalls)
        self.toolCallID = nil
        self.images = nil
    }

    init(_ entry: Transcript.Entry) throws {
        switch entry {
        case .instructions(let instructions):
            self.role = "system"
            self.content = Self.render(instructions.segments)
            self.thinking = nil
            self.name = nil
            self.toolName = nil
            self.toolCalls = nil
            self.toolCallID = nil
            self.images = try Self.encodedImages(instructions.segments)
        case .prompt(let prompt):
            self.role = "user"
            self.content = Self.render(prompt.segments)
            self.thinking = nil
            self.name = nil
            self.toolName = nil
            self.toolCalls = nil
            self.toolCallID = nil
            self.images = try Self.encodedImages(prompt.segments)
        case .response(let response):
            self.role = "assistant"
            self.content = Self.render(response.segments)
            self.thinking = nil
            self.name = nil
            self.toolName = nil
            self.toolCalls = nil
            self.toolCallID = nil
            self.images = try Self.encodedImages(response.segments)
        case .toolCalls(let calls):
            self.role = "assistant"
            self.content = ""
            self.thinking = nil
            self.name = nil
            self.toolName = nil
            self.toolCalls = try Self.decodeToolCalls(calls)
            self.toolCallID = nil
            self.images = nil
        case .toolOutput(let output):
            self.role = "tool"
            self.content = Self.render(output.segments)
            self.thinking = nil
            self.name = output.toolName
            self.toolName = output.toolName
            self.toolCalls = nil
            self.toolCallID = output.id
            self.images = try Self.encodedImages(output.segments)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, thinking, name
        case toolName = "tool_name"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case images
    }

    private static func render(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let value): return value.content.jsonString
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }

    private static func encodedImages(_ segments: [Transcript.Segment]) throws -> [String]? {
        let images = try segments.compactMap { segment -> String? in
            guard case .image(let image) = segment else { return nil }
            switch image.source {
            case .data(let data, _):
                return data.base64EncodedString()
            case .url(let url):
                throw ModelEndpointError.invalidRequest(
                    "Ollama requires image bytes; it cannot load image URL \(url.absoluteString)."
                )
            }
        }
        return images.isEmpty ? nil : images
    }

    private static func decodeToolCalls(_ calls: Transcript.ToolCalls) throws -> [RequestToolCall] {
        let data = try JSONEncoder().encode(calls)
        let payload = try JSONDecoder().decode(TranscriptToolCalls.self, from: data)
        return try payload.calls.map { try RequestToolCall($0) }
    }
}

private struct TranscriptToolCalls: Codable {
    let id: String
    let calls: [TranscriptToolCall]
}

private struct TranscriptToolCall: Codable {
    let id: String
    let toolName: String
    let arguments: GeneratedContent

}

private struct RequestToolCall: Encodable, Sendable {
    let id: String
    let type: String
    let function: RequestFunctionCall

    init(_ call: TranscriptToolCall) throws {
        self.id = call.id
        self.type = "function"
        self.function = try RequestFunctionCall(
            name: call.toolName,
            arguments: call.arguments.jsonString
        )
    }
}

private struct RequestFunctionCall: Encodable, Sendable {
    let name: String
    let arguments: AnyCodableValue

    init(name: String, arguments: String) throws {
        self.name = name
        guard let data = arguments.data(using: .utf8) else {
            throw ModelEndpointError.invalidRequest("Tool \(name) returned non-UTF8 arguments")
        }
        self.arguments = try JSONDecoder().decode(AnyCodableValue.self, from: data)
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
/// from the function's direct root `properties`. Hail passes the tool
/// schema through as emitted and decodes the returned arguments against
/// the original typed schema, so this adaptation only requires an object
/// root and never weakens execution validation.
private enum OllamaToolSchema {
    static func parameters(from schema: GenerationSchema) throws -> AnyCodableValue {
        let data = try JSONEncoder().encode(schema)
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        // Ollama builds its sampling grammar from the parameters schema but,
        // as with the `format` field, only resolves a `$ref` at the root. An
        // inner reference silently disables the whole constraint, which is
        // how models emit "days": "1" against a declared integer. Inlining
        // every local reference makes the declared argument types real: the
        // grammar rejects mistyped tokens at sampling time.
        let inlined = try OllamaEndpoint.inlineSchemaRefs(value)
        guard case .object = inlined else {
            throw ModelEndpointError.invalidRequest("Ollama tool parameters must be an object schema")
        }
        return inlined
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

/// A JSON value used for Ollama's arbitrary tool arguments and for schema
/// inlining (see OllamaEndpoint/inlineSchemaRefs(_:)).
enum AnyCodableValue: Codable, Equatable, Sendable {
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
