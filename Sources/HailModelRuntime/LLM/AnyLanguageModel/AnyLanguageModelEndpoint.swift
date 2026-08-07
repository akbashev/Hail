import AnyLanguageModel
import HailCore

/// A `ModelEndpoint` adapter that routes requests through AnyLanguageModel's
/// `LanguageModelSession`. This gives native tool calling and structured output
/// for any provider supported by AnyLanguageModel (OpenAI, Anthropic, Gemini,
/// Ollama, Open Responses, etc.).
public struct AnyLanguageModelEndpoint: ModelEndpoint {
    public let model: String
    private let languageModel: any LanguageModel
    private let temperature: Double

    public init(languageModel: some LanguageModel, modelIdentifier: String, temperature: Double = 0.7) {
        self.languageModel = languageModel
        self.model = modelIdentifier
        self.temperature = temperature
    }

    public func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>> {
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    let (transcript, prompt) = TranscriptMapping.transcriptAndPrompt(from: messages)

                    continuation.yield(.status("Generating..."))

                    let adaptedTools = try (tools ?? []).map { try AnyLanguageModelToolAdapter($0) }
                    let session = LanguageModelSession(
                        model: languageModel,
                        tools: adaptedTools,
                        transcript: transcript
                    )

                    // Keep Hail in control of tool execution.
                    let delegate = StopOnToolCallsDelegate()
                    session.toolExecutionDelegate = delegate

                    var options = GenerationOptions()
                    options.temperature = temperature

                    let response = try await session.respond(
                        to: prompt,
                        generating: String.self,
                        options: options
                    )

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
                        let text = response.content
                        continuation.yield(.text(text))
                        continuation.yield(.generated(text))
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
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    let (transcript, prompt) = TranscriptMapping.transcriptAndPrompt(from: messages)

                    continuation.yield(.status("Generating..."))

                    let adaptedTools = try (tools ?? []).map { try AnyLanguageModelToolAdapter($0) }
                    let session = LanguageModelSession(
                        model: languageModel,
                        tools: adaptedTools,
                        transcript: transcript
                    )

                    let delegate = StopOnToolCallsDelegate()
                    session.toolExecutionDelegate = delegate

                    var options = GenerationOptions()
                    options.temperature = temperature

                    let stream = session.streamResponse(
                        to: prompt,
                        generating: responseType,
                        options: options
                    )

                    var lastComplete: T?
                    for try await snapshot in stream {
                        if snapshot.rawContent.isComplete {
                            if let typed = snapshot.content as? T {
                                lastComplete = typed
                            } else {
                                lastComplete = try? T(snapshot.rawContent)
                            }
                        } else {
                            continuation.yield(.partialUpdated(snapshot.content))
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
}

// MARK: - Tool adapter

/// A lightweight wrapper that lets us build AnyLanguageModel tools directly from
/// an `LLMToolSchema` without requiring a full Hail ``Tool`` instance.
private struct AnyLanguageModelToolAdapter: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    init(_ schema: LLMToolSchema) throws {
        self.name = schema.function.name
        self.description = schema.function.description
        self.parameters = try Self.makeParameters(from: schema)
    }

    func call(arguments: GeneratedContent) async throws -> String {
        // This path is never reached because we stop on tool calls and execute
        // through Hail's ToolRegistry. The adapter only exists to register
        // the schema with the session.
        return ""
    }

    // MARK: - Schema conversion

    private static func makeParameters(from schema: LLMToolSchema) throws -> GenerationSchema {
        let properties = schema.function.parameters.properties ?? [:]
        let required = Set(schema.function.parameters.required ?? [])

        let dynamicProperties: [DynamicGenerationSchema.Property] = properties.map { key, prop in
            DynamicGenerationSchema.Property(
                name: key,
                description: prop.description,
                schema: dynamicSchema(for: prop),
                isOptional: !required.contains(key)
            )
        }

        let dynamic = DynamicGenerationSchema(
            name: schema.function.name,
            description: schema.function.description,
            properties: dynamicProperties
        )

        return try GenerationSchema(root: dynamic, dependencies: [])
    }

    private static func dynamicSchema(for prop: LLMToolSchema.PropertySchema) -> DynamicGenerationSchema {
        if let choices = prop.enumValues, !choices.isEmpty {
            return DynamicGenerationSchema(
                name: prop.type,
                description: prop.description,
                anyOf: choices
            )
        }

        switch prop.type {
        case "array":
            return DynamicGenerationSchema(
                arrayOf: prop.items.map(dynamicSchema(for:)) ?? DynamicGenerationSchema(type: String.self)
            )
        case "object":
            let properties = prop.properties ?? [:]
            let required = Set(prop.required ?? [])
            return DynamicGenerationSchema(
                name: "object",
                description: prop.description,
                properties: properties.map { key, nested in
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: nested.description,
                        schema: dynamicSchema(for: nested),
                        isOptional: !required.contains(key)
                    )
                }
            )
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
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
