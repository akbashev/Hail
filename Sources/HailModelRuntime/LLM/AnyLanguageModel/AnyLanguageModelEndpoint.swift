import AnyLanguageModel
import HailCore
import Logging
import Synchronization

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
    public let effectiveContextWindow: Int?
    public let tokenCounting: TokenCounting
    private let languageModel: any LanguageModel
    private let generationOptions: GenerationOptions
    private let reasoningSwitch: ReasoningSwitch?
    private let failures: ProviderFailures

    /// How a provider whose reasoning is on or off takes a request's
    /// ``ModelReasoningOverride``, such as Ollama's `think`. It's only given an actual
    /// override, `enabled` or `disabled`.
    public struct ReasoningSwitch: Sendable {
        let apply: @Sendable (_ thinking: ModelReasoningOverride, _ options: inout GenerationOptions) -> Void

        public init(
            _ apply:
                @escaping @Sendable (_ thinking: ModelReasoningOverride, _ options: inout GenerationOptions) -> Void
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
        reasoningSwitch: ReasoningSwitch? = nil,
        failures: ProviderFailures
    ) {
        self.languageModel = languageModel
        self.failures = failures
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
        think: Bool? = nil,
        transport: any HTTPTransport = makeDefaultTransport()
    ) -> Self {
        var options = GenerationOptions(temperature: temperature)
        // Ollama cuts a prompt longer than its context unless told not to, and the model then
        // answers without the prompt's beginning: such a request fails instead, which the
        // endpoint reads as the context being exceeded.
        var ollamaOptions: OllamaLanguageModel.CustomGenerationOptions = ["truncate": .bool(false)]
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
            languageModel: OllamaLanguageModel(baseURL: baseURL, model: model, transport: transport),
            modelIdentifier: model,
            temperature: temperature,
            effectiveContextWindow: contextWindow,
            generationOptions: options,
            reasoningSwitch: reasoningSwitch,
            failures: .ollama
        )
    }

    #if canImport(FoundationModels)
        /// Apple's on-device model, which counts a request's tokens exactly, where the system
        /// can, so the history is compacted before it's longer than the context.
        public static func system(
            model: String,
            temperature: Double,
            contextWindow: Int?
        ) -> Self {
            let languageModel = SystemLanguageModel.default
            var countTokens: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)?
            #if compiler(>=6.3)
                if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
                    countTokens = { entries, tools throws(AgentRuntimeError) in
                        do {
                            return try await languageModel.tokenCount(for: Self.offering(tools, in: entries))
                        } catch is CancellationError {
                            throw .cancelled
                        } catch {
                            throw .infrastructureFailure("Counting the request's tokens failed: \(error)")
                        }
                    }
                }
            #endif
            return Self(
                languageModel: languageModel,
                modelIdentifier: model,
                temperature: temperature,
                effectiveContextWindow: contextWindow,
                countTokens: countTokens,
                failures: .swiftErrors
            )
        }
    #endif

    /// `entries` with `tools` in their instructions, as a request gives them to the model.
    static func offering(_ tools: [ToolDefinition], in entries: [Transcript.Entry]) -> [Transcript.Entry] {
        guard !tools.isEmpty else { return entries }
        let definitions = tools.map {
            Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
        if case .instructions(let instructions) = entries.first {
            return [
                .instructions(
                    Transcript.Instructions(
                        segments: instructions.segments, toolDefinitions: instructions.toolDefinitions + definitions))
            ] + entries.dropFirst()
        }
        return [.instructions(Transcript.Instructions(segments: [], toolDefinitions: definitions))] + entries
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
            generationOptions: options,
            failures: .swiftErrors
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
                var attempts = RequestAttempts(
                    thinking: request.reasoning, thinkingCanBeTurnedOff: reasoningSwitch != nil)
                while true {
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
                        return .provideOutput([.text(.init(content: answer.reading))])
                    }
                    let ending: RequestAttempts.Ending
                    do {
                        try Task.checkCancellation()
                        let mapped = try TranscriptMapping.request(from: request.entries)

                        continuation.yield(.activity(.status(GeneratedContent("Generating"))))

                        let session = LanguageModelSession(
                            model: languageModel,
                            dynamicInstructions: OfferedInstructions(instructions: mapped.instructions, tools: offered),
                            history: mapped.history
                        )
                        session.toolExecutionDelegate = delegate

                        var response = ResponseSoFar<Output>()
                        let stream = session.streamResponse(
                            to: mapped.prompt,
                            generating: outputType,
                            options: options(
                                for: purpose, thinking: attempts.thinking, toolCallsLeft: request.toolCallsLeft)
                        )
                        for try await snapshot in stream {
                            await delegate.underWay()
                            let narration = response.receive(snapshot)
                            if !narration.isEmpty {
                                continuation.yield(.activity(.narrationDelta(GeneratedContent(narration))))
                            }
                            continuation.yield(.partialUpdated(snapshot.content))
                        }
                        for event in usageEvents(of: response, in: session) { continuation.yield(event) }

                        switch try response.ending() {
                        case .answered(let output):
                            continuation.yield(.generated(output))
                            continuation.finish()
                            return
                        case .wroteNothing:
                            ending = .wroteNothing
                        }
                    } catch {
                        ending = .failed(failures.read(error))
                    }
                    switch attempts.next(after: ending, progress: await delegate.progress) {
                    case .fail(let error):
                        continuation.yield(.failed(error))
                        continuation.finish()
                        return
                    case .askAgain(let wait):
                        Logger(label: "HailModelRuntime").warning(
                            "Asking the model again",
                            metadata: [
                                "model": .string(model),
                                "because": .string(String(describing: ending)),
                                "after": .string(wait.description),
                                "thinking": .string(String(describing: attempts.thinking)),
                            ]
                        )
                        do {
                            try await Task.sleep(for: wait)
                        } catch {
                            continuation.yield(.failed(.cancelled))
                            continuation.finish()
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The most rounds of tool calls one request takes, when its caller doesn't count its calls.
    /// The session answers each call inside the request, so an agent's whole turn is one request:
    /// making, checking and putting things back takes more rounds than a single answer does, and a
    /// turn calling tools without end still stops.
    static let maximumToolRounds = 32

    /// The most one answer takes, thinking included, whoever asks for it: room for a long answer,
    /// and an end to one that never ends.
    static let maximumAnswerTokens = 16384

    /// A caller that counts its calls stops the request itself: each round makes at least one
    /// call, so the round past its last call is one more than the calls it has left.
    private func options(
        for purpose: ModelRequestPurpose, thinking: ModelReasoningOverride, toolCallsLeft: Int?
    ) -> GenerationOptions {
        var options = generationOptions
        options.maximumToolRounds = toolCallsLeft.map { $0 + 1 } ?? Self.maximumToolRounds
        switch purpose {
        case .generation: options.maximumResponseTokens = options.maximumResponseTokens ?? Self.maximumAnswerTokens
        case .compaction(let maxOutputTokens): options.maximumResponseTokens = maxOutputTokens
        }
        if thinking != .providerDefault { reasoningSwitch?.apply(thinking, &options) }
        return options
    }

    /// What a response used, as the provider reported it: the usage of every request it made,
    /// which its session counts, as the session is made for this request alone; and how full the
    /// context was for its final request, against this endpoint's window.
    private func usageEvents<Output>(
        of response: ResponseSoFar<Output>,
        in session: LanguageModelSession
    ) -> [ModelEvent<Output>] {
        let usage = session.usage
        guard usage.input.totalTokenCount > 0 || usage.output.totalTokenCount > 0 else {
            return []
        }
        var events: [ModelEvent<Output>] = [
            .usage(
                ModelUsage(
                    inputTokens: Self.reportedCount(usage.input.totalTokenCount),
                    outputTokens: Self.reportedCount(usage.output.totalTokenCount),
                    reasoningTokens: Self.reportedCount(usage.output.reasoningTokenCount),
                    cachedReadTokens: Self.reportedCount(usage.input.cachedTokenCount),
                    totalTokens: usage.totalTokenCount,
                    source: .reported
                ))
        ]
        if let effectiveContextWindow, let final = response.usage,
            let used = Self.reportedCount(final.input.totalTokenCount)
        {
            events.append(
                .contextUsage(ContextUsage(usedTokens: used, limitTokens: effectiveContextWindow, source: .reported)))
        }
        return events
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
            generationOptions: options,
            failures: .swiftErrors
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

/// Sends each tool call the model makes to the agent's session, through `ask`, and gives the
/// model the session's answer.
private actor SessionToolsDelegate: ToolExecutionDelegate {
    private let ask: @Sendable (Transcript.ToolCall) async -> ToolExecutionDecision
    private(set) var progress = RequestProgress.notStarted

    /// The model is answering; once it called tools, that's what the request did.
    func underWay() {
        if progress == .notStarted { progress = .answering }
    }

    init(ask: @escaping @Sendable (Transcript.ToolCall) async -> ToolExecutionDecision) {
        self.ask = ask
    }

    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession) async {}

    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async
        -> ToolExecutionDecision
    {
        progress = .calledTools
        return await ask(toolCall)
    }

    func didExecuteToolCall(
        _ toolCall: Transcript.ToolCall, output: Transcript.ToolOutput, in session: LanguageModelSession
    ) async {}

    func didFailToolCall(
        _ toolCall: Transcript.ToolCall, error: any Error, in session: LanguageModelSession
    ) async {}
}
