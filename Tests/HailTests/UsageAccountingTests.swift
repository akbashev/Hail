import Foundation
import HailCore
import HailModelRuntime
import Testing

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
        state.apply(.modelUsage(usage, at: Date()), maxMemoryFragments: 10)
        state.apply(
            .contextUsage(ContextUsage(usedTokens: 12, limitTokens: 100, source: .reported), at: Date()),
            maxMemoryFragments: 10
        )

        #expect(state.conversationThread.isEmpty)
        #expect(state.usageSummary.requestCount == 1)
        #expect(state.usageSummary.inputTokens == 10)
        #expect(state.usageSummary.outputTokens == 4)
        #expect(state.usageSummary.reasoningTokens == 2)
        #expect(state.usageSummary.totalTokens == 14)
        #expect(state.latestContextUsage?.usedTokens == 12)
    }

    @Test("usage fields are backward-compatible in state snapshots")
    func oldSnapshotDecodes() throws {
        let old = #"{"agentID":"scout-usage","conversationThread":[],"workingMemory":[]}"#
        let state = try JSONDecoder().decode(AgentState.self, from: Data(old.utf8))
        #expect(state.usageSummary.requestCount == 0)
        #expect(state.latestContextUsage == nil)
    }

    @Test("old active-turn snapshots decode without new turn metadata")
    func oldActiveTurnSnapshotDecodes() throws {
        let old =
            #"{"agentID":"scout-usage","conversationThread":[],"workingMemory":[],"activeTurn":{"responded":false}}"#
        let state = try JSONDecoder().decode(AgentState.self, from: Data(old.utf8))
        #expect(state.activeTurn?.id == nil)
        #expect(state.activeTurn?.startedAt == nil)
        #expect(state.activeTurn?.responded == false)
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
            state.apply(event, maxMemoryFragments: 10)
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
            state.apply(event, maxMemoryFragments: 10)
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
                maxMemoryFragments: 10
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
            ),
            projectRootPath: "/tmp"
        )
        let routed = try await router.endpoint(
            for: "ollama/qwen2.5",
            agentID: agentID.rawValue
        )
        #expect(routed is OllamaEndpoint)
    }

    @Test("Ollama maps final-frame counts")
    func ollamaUsageStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = OllamaEndpoint(
            model: "qwen2.5",
            baseURL: URL(string: "http://localhost:11434")!,
            temperature: 0.7,
            numContext: 100,
            session: session
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            messages: [LLMMessage(role: .user, content: "hello")],
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
}

private final class OllamaStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body =
            [
                #"{"message":{"role":"assistant","content":"hello"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":11,"eval_count":3}"#,
            ].joined(separator: "\n") + "\n"
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
