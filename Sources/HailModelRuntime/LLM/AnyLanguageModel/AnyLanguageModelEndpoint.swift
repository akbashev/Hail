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
        countTokens: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil,
        generationOptions: GenerationOptions? = nil
    ) {
        self.languageModel = languageModel
        self.model = modelIdentifier
        self.generationOptions = generationOptions ?? GenerationOptions(temperature: temperature)
        self.effectiveContextWindow = effectiveContextWindow
        self.tokenCounting = countTokens.map(TokenCounting.available) ?? .unavailable
    }

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
        AsyncStream(ModelEvent<Output>.self) { continuation in
            let task = Task {
                do {
                    let mapped = try TranscriptMapping.transcriptAndPrompt(from: entries)

                    continuation.yield(.activity(.status(GeneratedContent("Generating..."))))

                    let adaptedTools = tools.map {
                        AuthorizedAnyLanguageModelTool(tool: $0, authority: authority)
                    }
                    let session = LanguageModelSession(
                        model: languageModel,
                        tools: adaptedTools,
                        transcript: mapped.transcript
                    )

                    let delegate = StopOnToolCallsDelegate()
                    session.toolExecutionDelegate = delegate

                    let stream = session.streamResponse(
                        to: mapped.prompt,
                        generating: outputType,
                        options: Self.options(generationOptions, for: purpose)
                    )

                    var lastComplete: Output?
                    var accumulatedText = ""
                    var narrationSegments: [Transcript.Segment] = []
                    // This is only an adapter-level rendering decision for
                    // observer activity. The requested output contract is
                    // `T` itself; Hail does not classify it as plain text or
                    // a report tool.
                    let isPlainText = Output.self == String.self
                    for try await snapshot in stream {
                        if isPlainText,
                            case .string(let snapshotText) = snapshot.rawContent.kind
                        {
                            let delta = Self.textDelta(
                                from: snapshotText,
                                after: &accumulatedText
                            )
                            if !delta.isEmpty {
                                narrationSegments.append(
                                    .text(.init(content: delta))
                                )
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

                    let generatedCalls = await delegate.generatedToolCalls
                    if !generatedCalls.isEmpty {
                        let calls = generatedCalls.map { call in
                            ToolCall(
                                id: call.id,
                                name: call.toolName,
                                arguments: call.arguments
                            )
                        }
                        let narration =
                            narrationSegments.isEmpty
                            ? nil
                            : Transcript.Response(
                                assetIDs: [],
                                segments: narrationSegments
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

    private static func options(
        _ base: GenerationOptions,
        for purpose: ModelRequestPurpose
    ) -> GenerationOptions {
        var options = base
        if case .compaction(let maxOutputTokens) = purpose {
            options.maximumResponseTokens = maxOutputTokens
        }
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
