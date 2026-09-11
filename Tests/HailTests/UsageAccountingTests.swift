import AnyLanguageModel
import Foundation
import HailCore
import Testing

@testable import HailModelRuntime

@Suite("Usage accounting")
struct UsageAccountingTests {
    private actor RequestCapture {
        private var body: Data?

        func store(_ body: Data) {
            self.body = body
        }

        func value() -> Data? {
            body
        }
    }

    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("usage"))

    private func prompt(_ content: String) -> Transcript.Entry {
        .prompt(.init(segments: [.text(.init(content: content))]))
    }

    @Test("usage events fold into durable totals without touching the transcript")
    func usageFoldsIntoState() {
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
            .contextUsage(ContextUsage(usedTokens: 12, limitTokens: 100, source: .reported), at: Date())
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
    func requestLifecycleProjection() {
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
        for event in events { state.apply(event) }

        #expect(state.activeTurn?.id == turnID)
        #expect(state.phase == .generating)
        #expect(state.modelRequests.count == 1)
        #expect(state.modelRequests.first?.outcome == .completed)
        #expect(state.modelRequests.first?.durationMilliseconds == 1_000)

        let history = AgentHistoryReader(events: events)
        #expect(history.modelRequests == state.modelRequests)
    }

    @Test("the actor-local request projection stays bounded")
    func recentRequestProjectionIsBounded() {
        var state = AgentState(agentID: agentID)
        for index in 0..<105 {
            state.apply(
                .modelRequestStarted(
                    ModelRequestRecord(
                        id: ModelRequestID("request-\(index)"),
                        turnID: TurnID("turn-\(index)"),
                        model: "qwen",
                        startedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                )
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
            countTokens: { entries, tools in entries.count * 10 + tools.count }
        )
        #expect(endpoint.effectiveContextWindow == 8_192)
        guard case .available(let countTokens) = endpoint.tokenCounting else {
            Issue.record("Expected Ollama token counting capability")
            return
        }
        let count = try await countTokens([prompt("hello")], [])
        #expect(count == 10)
    }

    @Test("Ollama maps final-frame usage and context occupancy")
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
            request: ModelRequest(input: "hello", entries: [prompt("hello")]),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .activity(.narrationDelta(let value)) = $0 { value == GeneratedContent("hello") } else { false }
            })
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

    @Test("Ollama rejects a thinking-only plain-text completion")
    func ollamaEmptyFinalResponse() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://empty.test",
            lines: [
                #"{"message":{"role":"assistant","thinking":"I should answer now.","content":""},"done":true}"#
            ]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "hello", entries: [prompt("hello")]),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(!events.contains { if case .generated = $0 { true } else { false } })
        #expect(
            events.contains {
                if case .failed(.invalidResponse(let message)) = $0 {
                    message == "Ollama completed without visible output or tool calls"
                } else {
                    false
                }
            }
        )
    }

    @Test("Ollama reports context exhaustion when a length finish fills the window")
    func ollamaLengthFinishWithFullWindow() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://overflow.test",
            numContext: 100,
            lines: [
                #"{"message":{"role":"assistant","content":"Partial answer."},"done":true,"done_reason":"length","prompt_eval_count":97,"eval_count":3}"#
            ]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "hello", entries: [prompt("hello")]),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(!events.contains { if case .generated = $0 { true } else { false } })
        #expect(
            events.contains {
                if case .failed(.contextLengthExceeded) = $0 { true } else { false }
            })
    }

    @Test("Ollama keeps a capped generation with window headroom a plain failure")
    func ollamaLengthFinishWithHeadroom() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://capped.test",
            numContext: 100_000,
            lines: [
                #"{"message":{"role":"assistant","content":"Partial answer."},"done":true,"done_reason":"length","prompt_eval_count":900,"eval_count":4096}"#
            ]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "hello", entries: [prompt("hello")]),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .failed(.requestFailed(let message)) = $0 {
                    message.contains("done_reason: length")
                } else {
                    false
                }
            })
    }

    @Test("Ollama treats an unaccounted length finish as context exhaustion")
    func ollamaLengthFinishWithoutCounts() async throws {
        let endpoint = ollamaEndpoint(
            baseURL: "http://legacy.test",
            numContext: 100,
            lines: [
                #"{"message":{"role":"assistant","content":"Partial answer."},"done":true,"done_reason":"length"}"#
            ]
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "hello", entries: [prompt("hello")]),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(
            events.contains {
                if case .failed(.contextLengthExceeded) = $0 { true } else { false }
            })
    }

    @Test("Ollama keeps an assistant tool round in one provider message")
    func ollamaCombinesAssistantToolRound() async throws {
        let capture = RequestCapture()
        let call = Transcript.ToolCall(
            id: "call-1",
            toolName: "now",
            arguments: try GeneratedContent(json: #"{"timeZone":"Europe/Berlin"}"#)
        )
        let calls = Transcript.ToolCalls(id: "calls-1", [call])
        let endpoint = OllamaEndpoint(
            model: "qwen3.5:9b",
            baseURL: URL(string: "http://capture.test")!,
            temperature: 0.2,
            transport: { body in
                await capture.store(body)
                return OllamaHTTPResponse(
                    statusCode: 200,
                    lines: Self.stubLines([
                        #"{"message":{"role":"assistant","content":"Done."},"done":true}"#
                    ])
                )
            }
        )

        let response = Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: "I will check the time."))]
        )
        for await _ in endpoint.stream(
            request: ModelRequest(
                input: "What time is it?",
                entries: [
                    prompt("What time is it?"),
                    .response(response),
                    .toolCalls(calls),
                ]
            ),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {}

        let body = try #require(await capture.value())
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(object["messages"] as? [[String: Any]])
        let assistantMessages = messages.filter { $0["role"] as? String == "assistant" }
        let assistant = try #require(assistantMessages.first)
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])

        #expect(assistantMessages.count == 1)
        #expect(assistant["content"] as? String == "I will check the time.")
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?["id"] as? String == "call-1")
        #expect(messages.filter { $0["role"] as? String == "tool" }.isEmpty)
    }

    private func ollamaEndpoint(
        baseURL: String,
        numContext: Int? = nil,
        lines: [String]
    ) -> OllamaEndpoint {
        OllamaEndpoint(
            model: "qwen3.5:9b-mlx",
            baseURL: URL(string: baseURL)!,
            temperature: 0.7,
            numContext: numContext,
            transport: { _ in
                OllamaHTTPResponse(statusCode: 200, lines: Self.stubLines(lines))
            }
        )
    }

    private static func stubLines(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}
