import AnyLanguageModel
import HailCore

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

    public init(
        languageModel: some LanguageModel,
        modelIdentifier: String,
        temperature: Double,
        effectiveContextWindow: Int? = nil,
        countTokens: (@Sendable ([LLMMessage], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        countInputTokens: (@Sendable (ModelInput, [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        generationOptions: GenerationOptions? = nil
    ) {
        self.languageModel = languageModel
        self.model = modelIdentifier
        self.generationOptions = generationOptions ?? GenerationOptions(temperature: temperature)
        self.effectiveContextWindow = effectiveContextWindow
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
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    let mapped = try TranscriptMapping.transcriptAndPrompt(from: input)

                    continuation.yield(.status("Generating..."))

                    let adaptedTools = (tools ?? []).map { SchemaOnlyAnyLanguageModelTool($0) }
                    let session = LanguageModelSession(
                        model: languageModel,
                        tools: adaptedTools,
                        transcript: mapped.transcript
                    )

                    // Keep Hail in control of tool execution.
                    let delegate = StopOnToolCallsDelegate()
                    session.toolExecutionDelegate = delegate

                    let stream = session.streamResponse(
                        to: mapped.prompt,
                        generating: String.self,
                        options: generationOptions
                    )

                    var accumulatedText = ""
                    for try await snapshot in stream {
                        guard case .string(let snapshotText) = snapshot.rawContent.kind else {
                            continue
                        }
                        let delta = Self.textDelta(
                            from: snapshotText,
                            after: &accumulatedText
                        )
                        if !delta.isEmpty {
                            continuation.yield(.text(delta))
                        }
                    }

                    let generatedCalls = await delegate.generatedToolCalls
                    if !generatedCalls.isEmpty {
                        for call in generatedCalls {
                            continuation.yield(.status("Calling \(call.toolName)."))
                            continuation.yield(
                                .toolCall(
                                    ToolCall(
                                        id: call.id,
                                        name: call.toolName,
                                        arguments: ToolArguments(json: call.arguments.jsonString)
                                    )))
                        }
                    } else {
                        continuation.yield(.generated(accumulatedText))
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    let mapped = try TranscriptMapping.transcriptAndPrompt(from: input)

                    continuation.yield(.status("Generating..."))

                    let adaptedTools = (tools ?? []).map { SchemaOnlyAnyLanguageModelTool($0) }
                    let session = LanguageModelSession(
                        model: languageModel,
                        tools: adaptedTools,
                        transcript: mapped.transcript
                    )

                    let delegate = StopOnToolCallsDelegate()
                    session.toolExecutionDelegate = delegate

                    let stream = session.streamResponse(
                        to: mapped.prompt,
                        generating: responseType,
                        options: generationOptions
                    )

                    var lastComplete: T?
                    var accumulatedText = ""
                    let isPlainText: Bool
                    switch T.outputContract {
                    case .plainText:
                        isPlainText = true
                    case .reportTool:
                        isPlainText = false
                    }
                    for try await snapshot in stream {
                        if isPlainText,
                            case .string(let snapshotText) = snapshot.rawContent.kind
                        {
                            let delta = Self.textDelta(
                                from: snapshotText,
                                after: &accumulatedText
                            )
                            if !delta.isEmpty {
                                continuation.yield(.text(delta))
                            }
                            // String is itself Generable. Keep the text delta
                            // for chat consumers, while also exposing the
                            // cumulative typed snapshot to generic clients.
                            continuation.yield(.partialUpdated(snapshot.content))
                        } else if !snapshot.rawContent.isComplete {
                            continuation.yield(.partialUpdated(snapshot.content))
                        }

                        if snapshot.rawContent.isComplete {
                            if let typed = snapshot.content as? T {
                                lastComplete = typed
                            } else {
                                lastComplete = try T(snapshot.rawContent)
                            }
                        }
                    }

                    let generatedCalls = await delegate.generatedToolCalls
                    if !generatedCalls.isEmpty {
                        for call in generatedCalls {
                            continuation.yield(.status("Calling \(call.toolName)."))
                            continuation.yield(
                                .toolCall(
                                    ToolCall(
                                        id: call.id,
                                        name: call.toolName,
                                        arguments: ToolArguments(json: call.arguments.jsonString)
                                    )))
                        }
                    } else if let outcome = lastComplete {
                        continuation.yield(.generated(outcome))
                    } else {
                        continuation.yield(
                            .failed(ModelEndpointError.invalidResponse("No complete structured response")))
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
}

// MARK: - Tool adapter

/// A lightweight wrapper that lets us build AnyLanguageModel tools directly from
/// a ``ToolDefinition`` without requiring a full Hail ``Tool`` instance.
private struct SchemaOnlyAnyLanguageModelTool: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    init(_ definition: ToolDefinition) {
        self.name = definition.name
        self.description = definition.description
        self.parameters = definition.parameters
    }

    func call(arguments: GeneratedContent) async throws -> String {
        // This path is never reached because we stop on tool calls and execute
        // through Hail's ToolRegistry. The adapter only exists to register
        // the schema with the session.
        return ""
    }

}

// MARK: - Delegate

/// Prevents AnyLanguageModel from executing tools itself. Hail wants to
/// own execution so it can enforce budgets and runtime accounting.
private actor StopOnToolCallsDelegate: ToolExecutionDelegate {
    private(set) var generatedToolCalls: [Transcript.ToolCall] = []

    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession) async {
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

    func didFailToolCall(_ toolCall: Transcript.ToolCall, error: any Error, in session: LanguageModelSession) async {}
}
