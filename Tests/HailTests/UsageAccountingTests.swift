import AnyLanguageModel
import HailCore
import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Usage accounting")
struct UsageAccountingTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("usage"))

    @Test("usage events fold into durable totals without touching the transcript")
    func usageFoldsIntoState() throws {
        var state = AgentState(agentID: agentID)
        let usage = ModelUsage(
            inputTokens: 10,
            outputTokens: 4,
            reasoningTokens: 2,
            totalTokens: 14,
            source: .reported
        )
        state.apply(.modelUsage(usage, at: Date()))
        state.apply(
            .contextUsage(ContextUsage(usedTokens: 12, limitTokens: 100, source: .reported), at: Date()),
        )

        #expect(state.conversationThread.isEmpty)
        #expect(state.usageSummary.requestCount == 1)
        #expect(state.usageSummary.inputTokens == 10)
        #expect(state.usageSummary.outputTokens == 4)
        #expect(state.usageSummary.reasoningTokens == 2)
        #expect(state.usageSummary.totalTokens == 14)
        #expect(state.latestContextUsage?.usedTokens == 12)
    }

    @Test("request lifecycle is replayable and queryable")
    func requestLifecycleProjection() throws {
        let turnID = TurnID("turn-1")
        let requestID = ModelRequestID("request-1")
        let startedAt = Date(timeIntervalSince1970: 1)
        let completedAt = Date(timeIntervalSince1970: 2)
        let record = ModelRequestRecord(
            id: requestID,
            turnID: turnID,
            model: "qwen",
            startedAt: startedAt
        )
        let usage = ModelUsage(inputTokens: 8, outputTokens: 3, totalTokens: 11, source: .reported)
        let events: [AgentEvent] = [
            .turnStarted(at: startedAt),
            .turnIdentified(id: turnID),
            .modelRequestStarted(record),
            .modelUsage(usage, at: completedAt),
            .modelRequestCompleted(
                id: requestID,
                usage: usage,
                durationMilliseconds: 1_000,
                at: completedAt
            ),
        ]

        var state = AgentState(agentID: agentID)
        for event in events {
            state.apply(event)
        }

        #expect(state.activeTurn?.id == turnID)
        #expect(state.phase == .generating)
        #expect(state.modelRequests.count == 1)
        #expect(state.modelRequests.first?.outcome == .completed)
        #expect(state.modelRequests.first?.durationMilliseconds == 1_000)

        let history = AgentHistoryReader(events: events)
        #expect(history.modelRequests == state.modelRequests)
    }

    @Test("compaction requests expose their phase and replay history finalizes interruptions")
    func compactionPhaseAndHistoryFinalization() throws {
        let turnID = TurnID("turn-compaction")
        let requestID = ModelRequestID("request-compaction")
        let startedAt = Date(timeIntervalSince1970: 10)
        let record = ModelRequestRecord(
            id: requestID,
            turnID: turnID,
            model: "qwen",
            kind: .compaction,
            startedAt: startedAt
        )
        let events: [AgentEvent] = [
            .turnStarted(at: startedAt),
            .turnIdentified(id: turnID),
            .modelRequestStarted(record),
        ]

        var state = AgentState(agentID: agentID)
        for event in events {
            state.apply(event)
        }
        #expect(state.phase == .compacting)

        var incremental = AgentHistoryReader()
        for event in events {
            incremental.apply(event)
        }
        #expect(incremental.modelRequests.first?.outcome == .running)
        incremental.finalize()
        #expect(incremental.modelRequests.first?.outcome == .interrupted)
        #expect(incremental.turns.first?.outcome == .interrupted)

        let replayed = AgentHistoryReader(events: events)
        #expect(replayed.modelRequests.first?.outcome == .interrupted)
    }

    @Test("the actor-local request projection stays bounded")
    func recentRequestProjectionIsBounded() throws {
        var state = AgentState(agentID: agentID)
        for index in 0..<105 {
            state.apply(
                .modelRequestStarted(
                    ModelRequestRecord(
                        id: ModelRequestID("request-\(index)"),
                        turnID: TurnID("turn-\(index)"),
                        model: "qwen",
                        startedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )),
            )
        }

        #expect(state.modelRequests.count == 100)
        #expect(state.modelRequests.first?.id == ModelRequestID("request-5"))
        #expect(state.modelRequests.last?.id == ModelRequestID("request-104"))
    }

    @Test("Ollama exposes configured context and tokenizer hooks")
    func ollamaCapabilities() async throws {
        let endpoint = OllamaEndpoint(
            model: "qwen2.5",
            baseURL: URL(string: "http://localhost:11434")!,
            temperature: 0.7,
            numContext: 8_192,
            countTokens: { messages, tools in messages.count * 10 + tools.count }
        )
        #expect(endpoint.effectiveContextWindow == 8_192)
        guard case .available(let countTokens) = endpoint.tokenCounting else {
            Issue.record("Expected Ollama token counting capability")
            return
        }
        let count = try await countTokens(
            [LLMMessage(role: .user, content: "hello")],
            []
        )
        #expect(count == 10)

        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(string: "http://localhost:11434")!]
            )
        )
        let routed = try await router.endpoint(
            for: "ollama/qwen2.5",
            agentID: agentID.rawValue,
            workspace: AgentWorkspace(rootPath: "/tmp")
        )
        #expect(routed is OllamaEndpoint)
    }

    @Test("Ollama maps final-frame counts")
    func ollamaUsageStream() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://localhost:11434",
            numContext: 100,
            lines: [
                #"{"message":{"role":"assistant","content":"hello"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":11,"eval_count":3}"#,
            ]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil
        ) {
            events.append(event)
        }

        #expect(events.contains { if case .text("hello") = $0 { true } else { false } })
        #expect(
            events.contains {
                if case .usage(let usage) = $0 { usage.inputTokens == 11 && usage.outputTokens == 3 } else { false }
            })
        #expect(
            events.contains {
                if case .contextUsage(let usage) = $0 {
                    usage.usedTokens == 11 && usage.limitTokens == 100
                } else {
                    false
                }
            })
        #expect(events.contains { if case .generated("hello") = $0 { true } else { false } })
    }

    @Test("Ollama maps fetched data at the provider boundary")
    func ollamaMapsFetchedData() async throws {
        var input = ModelInput(
            messages: [
                LLMMessage(role: .user, content: "What is shown?"),
                LLMMessage(
                    role: .assistant,
                    content: "",
                    thinking: "I should inspect the image before answering.",
                    toolCalls: [
                        LLMToolCall(
                            id: "fetch-1",
                            type: "function",
                            function: .init(name: "fetch_url", arguments: #"{"url":"https://example.test/a.jpg"}"#)
                        )
                    ]
                ),
            ]
        )
        input.appendToolOutput(
            callID: "fetch-1",
            name: "fetch_url",
            output: .data(
                ToolData(
                    body: Data([0, 1, 2]),
                    contentType: "image/jpeg",
                    source: URL(string: "https://example.test/a.jpg")
                )
            )
        )

        let endpoint = OllamaEndpoint(
            model: "qwen3.5:9b-mlx",
            baseURL: URL(string: "http://ollama.test")!,
            temperature: 0.7,
            transport: { body in
                let object = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let messages = try #require(object["messages"] as? [[String: Any]])
                let assistant = try #require(
                    messages.first { $0["role"] as? String == "assistant" }
                )
                #expect(assistant["thinking"] as? String == "I should inspect the image before answering.")
                let toolOutput = try #require(messages.last)
                #expect(toolOutput["role"] as? String == "tool")
                #expect(toolOutput["tool_name"] as? String == "fetch_url")
                #expect(toolOutput["tool_call_id"] as? String == "fetch-1")
                #expect(toolOutput["images"] as? [String] == ["AAEC"])
                return OllamaHTTPResponse(
                    statusCode: 200,
                    lines: Self.stubLines([
                        #"{"message":{"role":"assistant","content":"A test image."},"done":true}"#
                    ])
                )
            }
        )

        for await _ in endpoint.stream(input: input, tools: nil) {}
    }

    @Test("Ollama plain-text outputs do not require native structured output")
    func ollamaPlainTextContract() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://plain.test",
            rejectNativeStructuredOutput: true,
            lines: [
                #"{"message":{"role":"assistant","content":"hello"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true}"#,
            ]
        )

        var events: [ModelEvent<ChatResponse>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil,
            responseType: ChatResponse.self
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .generated(let response) = $0 { response.content == "hello" } else { false }
            })
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Ollama report-tool outputs work without native structured output")
    func ollamaReportToolContract() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://report.test",
            lines: [
                #"{"message":{"role":"assistant","content":"","tool_calls":[{"id":"report-1","function":{"name":"report_test_output","arguments":{"value":"done"}}}]},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":11,"eval_count":3}"#,
            ]
        )

        var events: [ModelEvent<TestReportOutput>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "report")]),
            tools: nil,
            responseType: TestReportOutput.self
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .generated(let output) = $0 { output.value == "done" } else { false }
            })
        #expect(
            !events.contains {
                if case .toolCall(let call) = $0 { call.name == TestReportOutput.reportToolName } else { false }
            })
    }

    @Test("Ollama error frames become request failures")
    func ollamaErrorFrame() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://error.test",
            lines: [#"{"error":"structured output is unavailable"}"#]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .failed(.requestFailed(let message)) = $0 {
                    message == "Ollama: structured output is unavailable"
                } else {
                    false
                }
            })
    }

    @Test("Ollama empty final responses are completed as empty text")
    func ollamaEmptyFinalResponse() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://empty.test",
            lines: [#"{"message":{"role":"assistant","content":""},"done":true}"#]
        )

        var events: [ModelEvent<ChatResponse>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil,
            responseType: ChatResponse.self
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .generated(let response) = $0 {
                    response.content.isEmpty
                } else {
                    false
                }
            })
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Ollama does not expose a tool result as the final response")
    func ollamaEmptyFinalResponseAfterToolRound() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://empty-after-tool.test",
            lines: [#"{"message":{"role":"assistant","content":""},"done":true}"#]
        )

        var events: [ModelEvent<ChatResponse>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [
                LLMMessage(role: .assistant, content: "", toolCalls: []),
                LLMMessage(
                    role: .tool,
                    content: "Created ticket T-1 assigned to @coder",
                    toolCallID: "call-1"
                ),
            ]),
            tools: nil,
            responseType: ChatResponse.self
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .generated(let response) = $0 {
                    response.content.isEmpty
                } else {
                    false
                }
            })
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Ollama sends the think switch only when configured")
    func ollamaThinkSwitchReachesRequestBody() async throws {
        func makeEndpoint(
            think: Bool?,
            check: @escaping @Sendable ([String: Any]) -> Void
        ) -> OllamaEndpoint {
            OllamaEndpoint(
                model: "qwen3:8b",
                baseURL: URL(string: "http://localhost:11434")!,
                temperature: 0.7,
                think: think,
                transport: { body in
                    let object =
                        try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                    check(object)
                    return OllamaHTTPResponse(
                        statusCode: 200,
                        lines: Self.stubLines([
                            #"{"message":{"role":"assistant","content":"ok"},"done":true}"#
                        ])
                    )
                }
            )
        }

        let disabled = makeEndpoint(think: false) { object in
            #expect(object["think"] as? Bool == false)
        }
        for await _ in disabled.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hi")]),
            tools: nil
        ) {}

        let standard = makeEndpoint(think: nil) { object in
            #expect(object["think"] == nil)
        }
        for await _ in standard.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hi")]),
            tools: nil
        ) {}

        let compaction = makeEndpoint(think: nil) { object in
            #expect(object["think"] as? Bool == false)
        }
        for await _ in compaction.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "summarize")]),
            tools: nil,
            purpose: .compaction(maxOutputTokens: 64)
        ) {}
    }

    @Test("Ollama rejects root union tool schemas instead of flattening them")
    func ollamaRejectsRootUnionToolSchema() async throws {
        let schema = ToolSchema.union(
            name: "TimerInput",
            description: "Timer input.",
            choices: [
                DynamicGenerationSchema(name: "CreateTimer", properties: [.init(name: "message", schema: ToolSchema.string(name: "Message"))]),
                DynamicGenerationSchema(name: "CancelTimer", properties: [.init(name: "id", schema: ToolSchema.string(name: "ID"))]),
            ]
        )
        let tool = ToolDefinition(name: "timer", description: "Manage timers.", parameters: schema)
        let endpoint = OllamaEndpoint(
            model: "qwen3:8b",
            baseURL: URL(string: "http://ollama.test")!,
            temperature: 0.7,
            transport: { _ in
                Issue.record("The transport must not be called for an unsupported root union")
                return OllamaHTTPResponse(statusCode: 200, lines: Self.stubLines([]))
            }
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "create a timer")]),
            tools: [tool]
        ) { events.append(event) }
        #expect(events.contains { if case .failed(.invalidRequest(let message)) = $0 { message.contains("root union") } else { false } })
    }

    @Test("Ollama resolves references inside array items")
    func ollamaResolvesArrayItemSchema() async throws {
        let item = DynamicGenerationSchema(
            name: "ReportItem",
            properties: [
                .init(name: "namespace", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "value", schema: DynamicGenerationSchema(type: String.self)),
            ]
        )
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "Report",
                properties: [
                    .init(name: "items", schema: DynamicGenerationSchema(arrayOf: item))
                ]
            ),
            dependencies: []
        )
        let tool = ToolDefinition(
            name: "report",
            description: "Report",
            parameters: schema
        )
        let endpoint = OllamaEndpoint(
            model: "qwen3:8b",
            baseURL: URL(string: "http://ollama.test")!,
            temperature: 0.7,
            transport: { body in
                let object = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let tools = try #require(object["tools"] as? [[String: Any]])
                let function = try #require(tools.first?["function"] as? [String: Any])
                let parameters = try #require(function["parameters"] as? [String: Any])
                let properties = try #require(parameters["properties"] as? [String: Any])
                let items = try #require(properties["items"] as? [String: Any])
                let itemSchema = try #require(items["items"] as? [String: Any])
                let itemProperties = try #require(itemSchema["properties"] as? [String: Any])
                #expect(itemProperties["namespace"] != nil)
                return OllamaHTTPResponse(
                    statusCode: 200,
                    lines: Self.stubLines([
                        #"{"message":{"role":"assistant","content":"ok"},"done":true}"#
                    ])
                )
            }
        )

        for await _ in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "report")]),
            tools: [tool]
        ) {}
    }

    private func ollamaEndpoint(
        baseURL: String,
        numContext: Int? = nil,
        rejectNativeStructuredOutput: Bool = false,
        lines: [String]
    ) -> OllamaEndpoint {
        OllamaEndpoint(
            model: "qwen3.5:9b-mlx",
            baseURL: URL(string: baseURL)!,
            temperature: 0.7,
            numContext: numContext,
            transport: { body in
                if rejectNativeStructuredOutput,
                    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                    object["format"] != nil
                {
                    return OllamaHTTPResponse(
                        statusCode: 501,
                        lines: Self.stubLines([#"{"error":"structured output is unavailable"}"#])
                    )
                }
                return OllamaHTTPResponse(statusCode: 200, lines: Self.stubLines(lines))
            }
        )
    }

    private static func stubLines(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

private struct TestReportOutput: AgentOutput, Codable, Sendable, Equatable {
    let value: String

    static let reportToolName = "report_test_output"

    init(_ content: GeneratedContent) throws {
        value = try content.value(String.self, forProperty: "value")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["value": value])
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: TestReportOutput.self,
            description: "Test report output",
            properties: [
                .init(name: "value", description: "The output value.", type: String.self)
            ]
        )
    }

    static var outputContract: AgentOutputContract {
        .reportTool(name: reportToolName, schema: reportToolSchema)
    }

    static var reportToolSchema: ToolDefinition {
        ToolDefinition(
            name: reportToolName,
            description: "Report the test output.",
            parameters: generationSchema
        )
    }
}
