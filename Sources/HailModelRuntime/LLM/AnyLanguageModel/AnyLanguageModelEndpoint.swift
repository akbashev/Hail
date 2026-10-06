import AnyLanguageModel
import HailCore
import Logging

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
                // Retry only this model request, with the same transcript. Tools
                // remain owned by Hail and completed results are already in it.
                for attempt in 0...1 {
                    var receivedSnapshot = false
                    let delegate = StopOnToolCallsDelegate()
                    do {
                        try Task.checkCancellation()
                        let mapped = try TranscriptMapping.transcriptAndPrompt(from: request.entries)

                        continuation.yield(.activity(.status(GeneratedContent("Generating"))))

                        let adaptedTools = tools.map {
                            AuthorizedAnyLanguageModelTool(tool: $0, authority: authority)
                        }
                        let session = LanguageModelSession(
                            model: languageModel,
                            tools: adaptedTools,
                            transcript: mapped.transcript
                        )

                        session.toolExecutionDelegate = delegate

                        let stream = session.streamResponse(
                            to: mapped.prompt,
                            generating: outputType,
                            options: options(for: purpose, thinking: request.reasoning)
                        )

                        var lastComplete: Output?
                        var latestUsage: LanguageModelSession.Usage?
                        var accumulatedText = ""
                        // This is only an adapter-level rendering decision for
                        // observer activity. The requested output contract is
                        // `T` itself; Hail does not classify it as plain text or
                        // a report tool.
                        let isPlainText = Output.self == String.self
                        for try await snapshot in stream {
                            receivedSnapshot = true
                            latestUsage = snapshot.usage
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
                                // String is itself Generable. Keep the text delta
                                // for chat consumers, while also exposing the
                                // cumulative typed snapshot to generic clients.
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

                        if let latestUsage,
                            latestUsage.input.totalTokenCount > 0
                                || latestUsage.output.totalTokenCount > 0
                        {
                            let inputTokens = Self.reportedCount(latestUsage.input.totalTokenCount)
                            let outputTokens = Self.reportedCount(latestUsage.output.totalTokenCount)
                            continuation.yield(
                                .usage(
                                    ModelUsage(
                                        inputTokens: inputTokens,
                                        outputTokens: outputTokens,
                                        reasoningTokens: Self.reportedCount(
                                            latestUsage.output.reasoningTokenCount
                                        ),
                                        cachedReadTokens: Self.reportedCount(
                                            latestUsage.input.cachedTokenCount
                                        ),
                                        totalTokens: latestUsage.totalTokenCount,
                                        source: .reported
                                    )))
                            if let effectiveContextWindow, let inputTokens {
                                continuation.yield(
                                    .contextUsage(
                                        ContextUsage(
                                            usedTokens: inputTokens,
                                            limitTokens: effectiveContextWindow,
                                            source: .reported
                                        )))
                            }
                        }

                        let generatedCalls = await delegate.generatedToolCalls
                        if !generatedCalls.isEmpty {
                            let calls = generatedCalls.map { call in
                                ToolCall(
                                    id: call.id,
                                    name: call.toolName,
                                    arguments: call.arguments
                                )
                            }
                            // The text the model wrote before its tool calls, as one
                            // segment: the deltas are for live observers, not separate
                            // pieces of the response.
                            let narration =
                                accumulatedText.isEmpty
                                ? nil
                                : Transcript.Response(
                                    assetIDs: [],
                                    segments: [.text(.init(content: accumulatedText))]
                                )
                            for call in calls {
                                continuation.yield(.activity(.status(GeneratedContent("Calling \(call.name)."))))
                            }
                            continuation.yield(
                                .toolsRequested(
                                    ModelToolRound(
                                        narration: narration,
                                        calls: calls
                                    )))
                        } else if let outcome = lastComplete {
                            continuation.yield(.generated(outcome))
                        } else {
                            continuation.yield(
                                .failed(ModelEndpointError.invalidResponse("No complete generated response")))
                        }

                        continuation.finish()
                        return
                    } catch {
                        let calls = await delegate.generatedToolCalls
                        if attempt == 0, !receivedSnapshot, calls.isEmpty,
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
            case .decodingFailure(let context): return .decodingError(context.debugDescription)
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

// MARK: - Delegate

/// Prevents AnyLanguageModel from executing tools itself. Hail wants to
/// own execution so it can enforce budgets and runtime accounting.
private actor StopOnToolCallsDelegate: ToolExecutionDelegate {
    private(set) var generatedToolCalls: [Transcript.ToolCall] = []

    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession)
        async
    {
        generatedToolCalls.append(contentsOf: toolCalls)
    }

    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async
        -> ToolExecutionDecision
    {
        .stop
    }

    func didExecuteToolCall(
        _ toolCall: Transcript.ToolCall, output: Transcript.ToolOutput, in session: LanguageModelSession
    ) async {}

    func didFailToolCall(
        _ toolCall: Transcript.ToolCall, error: any Error, in session: LanguageModelSession
    ) async {}
}
