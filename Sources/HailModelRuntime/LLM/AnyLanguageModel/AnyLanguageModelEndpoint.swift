import AnyLanguageModel
import HailCore
import Logging
import Synchronization

import struct AsyncHTTPClient.HTTPClientError
import struct Foundation.URLError

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A `ModelEndpoint` adapter that routes requests through AnyLanguageModel's
/// `LanguageModelSession`. This gives native tool calling and structured output
/// for any provider supported by AnyLanguageModel.
public struct AnyLanguageModelEndpoint: ModelEndpoint {
    public let model: String
    public let contextOwnership: ModelContextOwnership = .runtime
    public let effectiveContextWindow: Int?
    public let tokenCounting: TokenCounting
    private let languageModel: any LanguageModel
    private let generationOptions: GenerationOptions
    private let reasoningSwitch: ReasoningSwitch?

    /// How a provider whose reasoning is on or off takes a request's
    /// ``ModelReasoningOverride``, such as Ollama's `think`. It's only given an actual
    /// override, `enabled` or `disabled`.
    public struct ReasoningSwitch: Sendable {
        let apply: @Sendable (_ thinking: ModelReasoningOverride, _ options: inout GenerationOptions) -> Void

        public init(
            _ apply: @escaping @Sendable (_ thinking: ModelReasoningOverride, _ options: inout GenerationOptions) -> Void
        ) {
            self.apply = apply
        }
    }

    public init(
        languageModel: some LanguageModel,
        modelIdentifier: String,
        temperature: Double,
        effectiveContextWindow: Int? = nil,
        countTokens: (
            @Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int
        )? = nil,
        generationOptions: GenerationOptions? = nil,
        reasoningSwitch: ReasoningSwitch? = nil
    ) {
        self.languageModel = languageModel
        self.model = modelIdentifier
        self.generationOptions = generationOptions ?? GenerationOptions(temperature: temperature)
        self.reasoningSwitch = reasoningSwitch
        self.effectiveContextWindow = effectiveContextWindow
        self.tokenCounting = countTokens.map(TokenCounting.available) ?? .unavailable
    }

    public static func ollama(
        model: String,
        baseURL: URL,
        temperature: Double,
        contextWindow: Int? = nil,
        keepAlive: String? = nil,
        think: Bool? = nil
    ) -> Self {
        var options = GenerationOptions(temperature: temperature)
        var ollamaOptions: OllamaLanguageModel.CustomGenerationOptions = [:]
        if let contextWindow {
            ollamaOptions["num_ctx"] = .int(contextWindow)
        }
        if let keepAlive {
            ollamaOptions["keep_alive"] = .string(keepAlive)
        }
        if let think {
            ollamaOptions["think"] = .bool(think)
        }
        options[custom: OllamaLanguageModel.self] = ollamaOptions

        // A request's override sets `think`, unless the configuration already fixed it.
        let reasoningSwitch: ReasoningSwitch? =
            think != nil
            ? nil
            : ReasoningSwitch { thinking, options in
                var ollamaOptions = options[custom: OllamaLanguageModel.self] ?? [:]
                ollamaOptions["think"] = .bool(thinking == .enabled)
                options[custom: OllamaLanguageModel.self] = ollamaOptions
            }
        return Self(
            languageModel: OllamaLanguageModel(baseURL: baseURL, model: model),
            modelIdentifier: model,
            temperature: temperature,
            effectiveContextWindow: contextWindow,
            generationOptions: options,
            reasoningSwitch: reasoningSwitch
        )
    }

    public static func llamaCPP(
        model: String,
        modelPath: String,
        temperature: Double,
        contextWindow: Int,
        gpuLayers: Int32 = LlamaLanguageModel.defaultGPULayerCount
    ) -> Self {
        var options = GenerationOptions(temperature: temperature)
        options[custom: LlamaLanguageModel.self] = .init(
            contextSize: UInt32(contextWindow),
            temperature: Float(temperature)
        )
        return Self(
            languageModel: LlamaLanguageModel(
                modelPath: modelPath,
                gpuLayers: gpuLayers
            ),
            modelIdentifier: model,
            temperature: temperature,
            effectiveContextWindow: contextWindow,
            generationOptions: options
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
        AsyncStream(ModelEvent<Output>.self) { continuation in
            let task = Task {
                // Retry only a request that failed before it produced anything or asked for a
                // tool call: one that did is under way in the agent's session.
                for attempt in 0...1 {
                    // The tools the agent's session offers this request: what it starts with,
                    // then what each answered call leaves it offering.
                    let offered = OfferedTools(tools)
                    // Each tool call the model makes goes to the agent's session, and the model
                    // goes on with the session's answer, in this same request.
                    let delegate = SessionToolsDelegate { call in
                        // The text written before it streams as narration; it isn't tied to the
                        // call, which reaches the delegate independently of the relayed text.
                        let (reply, answer) = ToolReply.awaiting()
                        continuation.yield(.activity(.status(GeneratedContent("Calling \(call.toolName)."))))
                        continuation.yield(
                            .toolCall(
                                ModelToolCall(
                                    call: ToolCall(id: call.id, name: call.toolName, arguments: call.arguments),
                                    reply: reply)))
                        guard let answer = await answer.first(where: { _ in true }) else {
                            // Cancelled: the request is over, and nothing more runs in it.
                            return .stop
                        }
                        offered.replace(answer.tools)
                        // TEMP DUMP: what the model reads back, and the tools it's offered next.
                        tempDump("TEMP DUMP call \(call.toolName) \(call.arguments.jsonString)\nTEMP DUMP reads:\n\(answer.reading)\nTEMP DUMP offered:\n\(tempTools(answer.tools))")
                        return .provideOutput([.text(.init(content: answer.reading))])
                    }
                    do {
                        try Task.checkCancellation()
                        let mapped = try TranscriptMapping.request(from: request.entries)
                        // TEMP DUMP: the request as it starts.
                        tempDump("TEMP DUMP request\ninstructions: \(String(describing: mapped.instructions))\nhistory: \(mapped.history)\nprompt: \(String(describing: mapped.prompt))\nTEMP DUMP tools:\n\(tempTools(offered.current))")

                        continuation.yield(.activity(.status(GeneratedContent("Generating"))))

                        let session = LanguageModelSession(
                            model: languageModel,
                            dynamicInstructions: OfferedInstructions(instructions: mapped.instructions, tools: offered),
                            history: mapped.history
                        )

                        session.toolExecutionDelegate = delegate
                        // On a typed repeated-round failure, continue from the completed tool
                        // exchanges in the same session transcript.
                        session.transcriptErrorHandlingPolicy = .preserveTranscript

                        var lastComplete: Output?
                        var latestUsage: LanguageModelSession.Usage?
                        // How full the context is: the latest request's input, not the usage of
                        // every request a response with tools made, added up.
                        var latestContext: LanguageModelSession.Usage.Input?
                        var accumulatedText = ""
                        let isPlainText = Output.self == String.self
                        var repeatedRoundRecoveryUsed = false
                        while true {
                            let prompt = repeatedRoundRecoveryUsed
                                ? Prompt("The previous set of tool calls with the same names and arguments completed. This repeated set was not run. Continue from the previous results or choose a different next step.")
                                : mapped.prompt
                            do {
                                let stream = session.streamResponse(
                                    to: prompt,
                                    generating: outputType,
                                    options: options(for: purpose, thinking: request.reasoning)
                                )
                                for try await snapshot in stream {
                                    await delegate.underWay()
                                    latestUsage = snapshot.usage
                                    latestContext = snapshot.context
                                    if isPlainText,
                                        case .string(let snapshotText) = snapshot.rawContent.kind
                                    {
                                        let delta = Self.textDelta(
                                            from: snapshotText,
                                            after: &accumulatedText
                                        )
                                        if !delta.isEmpty {
                                            continuation.yield(.activity(.narrationDelta(GeneratedContent(delta))))
                                        }
                                        continuation.yield(.partialUpdated(snapshot.content))
                                    } else if !snapshot.rawContent.isComplete {
                                        continuation.yield(.partialUpdated(snapshot.content))
                                    }
                                    if snapshot.rawContent.isComplete {
                                        if let typed = snapshot.content as? Output {
                                            lastComplete = typed
                                        } else {
                                            lastComplete = try Output(snapshot.rawContent)
                                        }
                                    }
                                }
                                break
                            } catch {
                                guard !repeatedRoundRecoveryUsed, Self.isRepeatedToolRoundFailure(error) else {
                                    throw error
                                }
                                repeatedRoundRecoveryUsed = true
                                lastComplete = nil
                                latestUsage = nil
                                latestContext = nil
                                accumulatedText = ""
                                continuation.yield(.activity(.status(GeneratedContent("Continuing after repeated tool calls"))))
                            }
                        }

                        if let outcome = lastComplete {
                            continuation.yield(.generated(outcome))
                        } else {
                            continuation.yield(
                                .failed(ModelEndpointError.invalidResponse("No complete generated response")))
                        }

                        continuation.finish()
                        return
                    } catch {
                        if attempt == 0, await delegate.progress == .notStarted,
                            !Task.isCancelled, Self.isTransientTransportFailure(error)
                        {
                            Logger(label: "HailModelRuntime").warning(
                                "Retrying model request before output",
                                metadata: [
                                    "model": .string(model),
                                    "error": .string(String(describing: error)),
                                ]
                            )
                            do {
                                try await Task.sleep(for: .seconds(1))
                            } catch {
                                continuation.yield(.failed(.cancelled))
                                continuation.finish()
                                return
                            }
                            continue
                        }
                        continuation.yield(.failed(Self.endpointError(error)))
                        continuation.finish()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isRepeatedToolRoundFailure(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelSession.GenerationError,
            case .repeatedToolCallRound = error
        else { return false }
        return true
    }

    private static func isTransientTransportFailure(_ error: any Error) -> Bool {
        if let error = error as? HTTPClientError {
            return error == .deadlineExceeded || error == .readTimeout
                || error == .writeTimeout || error == .connectTimeout
                || error == .remoteConnectionClosed
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func endpointError(_ error: any Error) -> ModelEndpointError {
        if Task.isCancelled || error is CancellationError
            || (error as? HTTPClientError) == .cancelled
            || (error as? URLError)?.code == .cancelled
        {
            return .cancelled
        }
        if let error = error as? ModelEndpointError { return error }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextLengthExceeded
            case .rateLimited: return .rateLimit
            case .decodingFailure(let context), .repeatedToolCallRound(let context):
                return .decodingError(context.debugDescription)
            default: break
            }
        }
        let message = String(describing: error)
        if isContextLengthError(message) { return .contextLengthExceeded }
        return .requestFailed(message)
    }

    private func options(for purpose: ModelRequestPurpose, thinking: ModelReasoningOverride) -> GenerationOptions {
        var options = generationOptions
        if case .compaction(let maxOutputTokens) = purpose {
            options.maximumResponseTokens = maxOutputTokens
        }
        if thinking != .providerDefault { reasoningSwitch?.apply(thinking, &options) }
        return options
    }

    /// AnyLanguageModel response streams expose the content generated so far,
    /// rather than a token delta. Hail's model-event contract uses deltas, so
    /// calculate the suffix before forwarding the fragment.
    private static func textDelta(
        from snapshot: String,
        after accumulated: inout String
    ) -> String {
        guard !snapshot.isEmpty else { return "" }
        if snapshot.hasPrefix(accumulated) {
            let start = snapshot.index(snapshot.startIndex, offsetBy: accumulated.count)
            let delta = String(snapshot[start...])
            accumulated = snapshot
            return delta
        }

        // A provider that replaces its partial snapshot is still represented
        // faithfully: reset the accumulator and publish the replacement.
        accumulated = snapshot
        return snapshot
    }

    private static func isContextLengthError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("context length")
            || normalized.contains("context window")
            || normalized.contains("prompt is too long")
            || normalized.contains("input is too long")
            || normalized.contains("maximum context")
    }

    private static func reportedCount(_ count: Int) -> Int? {
        count > 0 ? count : nil
    }
}

public actor LlamaCPPEndpointCache {
    private struct Key: Hashable {
        let modelPath: String
        let gpuLayers: Int32
    }

    private var models: [Key: LlamaLanguageModel] = [:]

    public init() {}

    public func endpoint(
        model: String,
        modelPath: String,
        temperature: Double,
        contextWindow: Int,
        gpuLayers: Int32
    ) -> AnyLanguageModelEndpoint {
        let key = Key(
            modelPath: modelPath,
            gpuLayers: gpuLayers
        )
        let languageModel: LlamaLanguageModel
        if let loaded = models[key] {
            languageModel = loaded
        } else {
            let loaded = LlamaLanguageModel(modelPath: modelPath, gpuLayers: gpuLayers)
            models[key] = loaded
            languageModel = loaded
        }
        var options = GenerationOptions(temperature: temperature)
        options[custom: LlamaLanguageModel.self] = .init(
            contextSize: UInt32(contextWindow),
            temperature: Float(temperature)
        )
        return AnyLanguageModelEndpoint(
            languageModel: languageModel,
            modelIdentifier: model,
            temperature: temperature,
            effectiveContextWindow: contextWindow,
            generationOptions: options
        )
    }
}

// MARK: - The agent's session, from inside the request

/// The tools the agent's session offers a request, as they change: each answered call leaves
/// the session offering what it offers then.
private final class OfferedTools: Sendable {
    private let tools: Mutex<[AnyTool]>

    init(_ tools: [AnyTool]) {
        self.tools = Mutex(tools)
    }

    var current: [AnyTool] { tools.withLock { $0 } }

    func replace(_ tools: [AnyTool]) {
        self.tools.withLock { $0 = tools }
    }
}

/// What the model sees of the agent's session before each step of its request: the
/// instructions, and the tools the session offers now.
private struct OfferedInstructions: DynamicInstructions {
    let instructions: Instructions?
    let tools: OfferedTools

    var body: some DynamicInstructions {
        if let instructions { instructions }
        tools.current.map { OfferedTool($0) as any AnyLanguageModel.Tool }
    }
}

/// How far a request got: one under way has produced output or a tool call, which may already
/// have run in the agent's session, so it's never retried.
private enum RequestProgress {
    case notStarted
    case underWay
}

/// Sends each tool call the model makes to the agent's session, through `ask`, and gives the
/// model the session's answer.
private actor SessionToolsDelegate: ToolExecutionDelegate {
    private let ask: @Sendable (Transcript.ToolCall) async -> ToolExecutionDecision
    private(set) var progress = RequestProgress.notStarted

    func underWay() {
        progress = .underWay
    }

    init(ask: @escaping @Sendable (Transcript.ToolCall) async -> ToolExecutionDecision) {
        self.ask = ask
    }

    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession) async {}

    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async
        -> ToolExecutionDecision
    {
        progress = .underWay
        return await ask(toolCall)
    }

    func didExecuteToolCall(
        _ toolCall: Transcript.ToolCall, output: Transcript.ToolOutput, in session: LanguageModelSession
    ) async {}

    func didFailToolCall(
        _ toolCall: Transcript.ToolCall, error: any Error, in session: LanguageModelSession
    ) async {}
}

// TEMP DUMP: helpers, removed with the dump.
private func tempDump(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func tempTools(_ tools: [AnyTool]) -> String {
    var lines: [String] = []
    for tool in tools {
        let schema = (try? JSONEncoder().encode(tool.schema.parameters)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        lines.append("  " + tool.name + ": " + tool.description + "\n    " + schema)
    }
    return lines.joined(separator: "\n")
}
