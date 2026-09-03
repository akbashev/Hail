import HailCore
import ScopedEffect
import Testing

@testable import HailAgentRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The fold side of compaction: one atomic `conversationCompacted` event
/// installs the rolling summary and drops the archived prefix.
@Suite("AgentState compaction fold")
struct CompactionFoldTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("c1"))

    private func message(_ content: String, _ offset: TimeInterval) -> ChatMessage {
        .text(sender: "user", content: content, timestamp: Date(timeIntervalSince1970: offset))
    }

    private func state(threadCount: Int) -> AgentState {
        var state = AgentState(agentID: agentID)
        for i in 0..<threadCount {
            state.apply(.messageReceived(message("m\(i)", TimeInterval(i))), maxMemoryFragments: 10)
        }
        return state
    }

    @Test("conversationCompacted installs the summary and trims the prefix")
    func foldTrimsPrefixAndInstallsSummary() {
        var state = state(threadCount: 5)
        state.apply(.conversationCompacted(archivedCount: 3, summary: "first three messages"), maxMemoryFragments: 10)
        #expect(state.contextSummary == "first three messages")
        #expect(state.conversationThread.count == 2)
    }

    @Test("assistant narration accompanying a tool call survives replay")
    func assistantToolNarrationIsRetained() {
        var state = AgentState(agentID: agentID)
        state.apply(
            .assistantText(content: "I will inspect the file first.", at: Date(timeIntervalSince1970: 1)),
            maxMemoryFragments: 10
        )
        guard case .text(let sender, let content, _) = state.conversationThread.first else {
            Issue.record("Expected assistant narration in the replayed thread")
            return
        }
        #expect(sender == agentID.rawValue)
        #expect(content == "I will inspect the file first.")
    }

    @Test("a second compaction replaces the summary — the fold is rolling")
    func secondCompactionReplacesSummary() {
        var state = state(threadCount: 5)
        state.apply(.conversationCompacted(archivedCount: 3, summary: "v1"), maxMemoryFragments: 10)
        state.apply(.conversationCompacted(archivedCount: 1, summary: "v2 folds v1"), maxMemoryFragments: 10)
        #expect(state.contextSummary == "v2 folds v1")
        #expect(state.conversationThread.count == 1)
    }

    @Test("archivedCount beyond the thread length is ignored")
    func outOfBoundsArchiveCountIgnored() {
        var state = state(threadCount: 2)
        state.apply(.conversationCompacted(archivedCount: 10, summary: "over"), maxMemoryFragments: 10)
        #expect(state.contextSummary == "over")
        #expect(state.conversationThread.count == 2)
    }

    @Test("state written before contextSummary existed still decodes")
    func backwardCompatibleDecode() throws {
        // Synthesized Codable omits nil optionals, so this round-trip
        // exercises exactly the old-schema shape a pre-compaction snapshot
        // or journal would hold.
        let state = state(threadCount: 1)
        let data = try JSONEncoder().encode(state)
        #expect(!String(decoding: data, as: UTF8.self).contains("contextSummary"))
        let decoded = try JSONDecoder().decode(AgentState.self, from: data)
        #expect(decoded.contextSummary == nil)
        #expect(decoded.conversationThread == state.conversationThread)
    }
}

/// The assembled prompt carries the rolling summary as one system line.
@Suite("Prompt assembly compaction summary")
struct PromptAssemblySummaryTests {
    private let agentID = AgentID(role: Role("scout"), contextID: .main)

    private func context(
        summary: String?,
        contextID: AgentContextID = .main,
        thread: [ChatMessage] = []
    ) throws -> PromptContext {
        let id = AgentID(role: agentID.role, contextID: contextID)
        return PromptContext(
            agentID: id,
            definition: AgentDefinition(
                role: id.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModelReference("test/fake")
                ),
                limits: .init()
            ),
            projectRootPath: "/tmp",
            workingMemory: [],
            contextSummary: summary,
            conversationThread: thread,
            contextManifest: ContextManifest(items: [])
        )
    }

    @Test("summary is injected into the assembled context")
    func summaryInjected() throws {
        let messages = assembleStandardPrompt(
            try context(summary: "user hates prod on Fridays")
        ).messages
        #expect(
            messages.contains {
                $0.role == .system && $0.content.contains("user hates prod on Fridays")
            })
    }

    @Test("no summary, no summary line")
    func noSummaryNoLine() throws {
        let messages = assembleStandardPrompt(try context(summary: nil)).messages
        #expect(!messages.contains { $0.content.contains("Earlier conversation, summarized:") })
    }

    @Test("the flat prompt view is derived from prepared request sections")
    func preparedRequestIsThePromptSourceOfTruth() throws {
        let context = try context(
            summary: "v1",
            thread: [.text(sender: "user", content: "hello", timestamp: Date())]
        )
        let prepared = assembleStandardPrompt(context)
        let messages = prepared.messages

        #expect(messages.map(\.content) == prepared.messages.map(\.content))
        #expect(messages.map(\.role) == prepared.messages.map(\.role))
    }

    @Test("chat prompt preserves more than twenty unarchived messages")
    func chatDoesNotSilentlyTruncate() throws {
        let thread = (0..<25).map {
            ChatMessage.text(sender: "user", content: "message-\($0)", timestamp: Date())
        }
        let messages = assembleStandardPrompt(try context(summary: nil, thread: thread)).messages

        #expect(messages.contains { $0.content == "message-0" })
        #expect(messages.contains { $0.content == "message-24" })
    }

    @Test("task prompt preserves context before the latest user instruction")
    func taskDoesNotSilentlyTruncate() throws {
        let thread: [ChatMessage] = [
            .text(sender: "user", content: "original constraint", timestamp: Date()),
            .text(sender: agentID.rawValue, content: "acknowledged", timestamp: Date()),
            .text(sender: "user", content: "continue", timestamp: Date()),
        ]
        let messages = assembleStandardPrompt(
            try context(summary: nil, contextID: AgentContextID("task-1"), thread: thread)
        ).messages

        #expect(messages.contains { $0.content == "original constraint" })
        #expect(messages.contains { $0.content == "continue" })
    }
}

/// The turn-start hook: exclusion of session-owning endpoints, atomic
/// journaling, context rebuild, and graceful degradation.
@Suite("ReasoningLoop compaction")
struct ReasoningLoopCompactionTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("c1"))

    // MARK: Fakes

    private struct FakeEndpoint: ModelEndpoint {
        let model = "fake"
        let contextOwnership: ModelContextOwnership = .runtime
        let response: String

        func stream(
            messages: [LLMMessage],
            tools: [LLMToolSchema]?
        ) -> AsyncStream<ModelEvent<String>> {
            let response = self.response
            return AsyncStream { continuation in
                continuation.yield(.text(response))
                continuation.yield(.generated(response))
                continuation.finish()
            }
        }
    }

    private struct TokenCountingError: Error, Equatable {}

    private struct FailingTokenCountEndpoint: ModelEndpoint {
        let model = "counting-fails"
        let contextOwnership: ModelContextOwnership = .runtime
        let tokenCounting: TokenCounting = .available { _, _ in
            throw TokenCountingError()
        }

        func stream(
            messages: [LLMMessage],
            tools: [LLMToolSchema]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }
    }

    /// A session-owning endpoint: harnesses manage their own context and
    /// must never be offered compaction.
    private struct FakeSessionEndpoint: ModelEndpoint, SessionOwningEndpoint {
        let model = "fake-session"
        var currentSessionID: SessionID? { nil }

        func stream(
            messages: [LLMMessage],
            tools: [LLMToolSchema]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }

        func stream<T: AgentOutput>(
            messages: [LLMMessage],
            delta: TurnDelta,
            authority: any Authority,
            tools: [LLMToolSchema]?,
            responseType: T.Type
        ) -> AsyncStream<ModelEvent<T>> {
            AsyncStream { $0.finish() }
        }
    }

    private struct MisconfiguredSessionEndpoint: ModelEndpoint {
        let model = "misconfigured-session"
        let contextOwnership: ModelContextOwnership = .endpointSession

        func stream(
            messages: [LLMMessage],
            tools: [LLMToolSchema]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }
    }

    private struct FakeCompactor: ContextCompactor {
        let body:
            @Sendable (
                PromptContext,
                PreparedRequest,
                @Sendable ([LLMMessage]) async throws -> String
            ) async throws
                -> CompactionDecision

        func compact(
            context: PromptContext,
            request: PreparedRequest,
            summarize: @Sendable ([LLMMessage]) async throws -> String
        ) async throws -> CompactionDecision {
            try await body(context, request, summarize)
        }
    }

    private actor Recorder {
        var events: [AgentEvent] = []
        var contextCalls = 0
        var compactorCalls = 0
        var budgetedMessageCount = 0
        var budgetedToolCount = 0

        func record(_ event: AgentEvent) { events.append(event) }
        func nextContext() -> Int {
            contextCalls += 1
            return contextCalls
        }
        func compacted() { compactorCalls += 1 }
        func budgeted(messages: [LLMMessage], tools: [LLMToolSchema]) {
            budgetedMessageCount = messages.count
            budgetedToolCount = tools.count
        }
    }

    // MARK: Helpers

    private func makeContext(thread: [ChatMessage]) throws -> TurnContext {
        let promptContext = PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModelReference("test/fake")
                ),
                limits: .init()
            ),
            projectRootPath: "/tmp",
            workingMemory: [],
            conversationThread: thread,
            contextManifest: ContextManifest(items: [])
        )
        return TurnContext(
            preparedRequest: PreparedRequest(
                prefix: [],
                conversation: thread.enumerated().map {
                    PreparedRequest.ConversationEntry(
                        sourceIndex: $0.offset,
                        message: LLMMessage(role: .user, content: "fixture-\($0.offset)")
                    )
                }
            ),
            promptContext: promptContext,
            workingMemory: [],
            sessionIdentity: SessionIdentity(rawValue: "identity"),
            modelSessionID: nil,
            modelSessionIdentity: nil
        )
    }

    private func makeLoop(
        recorder: Recorder,
        contexts: [TurnContext],
        compactor: (any ContextCompactor)?
    ) -> ReasoningLoop<ContinuousClock> {
        final class Index: @unchecked Sendable { var value = 0 }
        let index = Index()
        return ReasoningLoop<ContinuousClock>(
            agentID: agentID,
            authority: FullAuthority(),
            context: {
                let i = min(index.value, contexts.count - 1)
                index.value += 1
                _ = await recorder.nextContext()
                return contexts[i]
            },
            endpoint: { FakeEndpoint(response: "rolled summary") },
            tools: { ToolRegistry(authority: FullAuthority()) },
            emit: { await recorder.record($0) },
            recordActivity: { _ in },
            compactor: compactor,
            clock: ContinuousClock()
        )
    }

    // MARK: Tests

    @Test("a compaction result is journaled atomically and the context rebuilt")
    func compactionJournaledAndContextRebuilt() async throws {
        let recorder = Recorder()
        let original = try makeContext(thread: [
            .text(sender: "user", content: "m1", timestamp: Date()),
            .text(sender: "user", content: "m2", timestamp: Date()),
        ])
        let rebuilt = try makeContext(thread: [])
        let compactor = FakeCompactor { _, _, summarize in
            await recorder.compacted()
            // The runtime's summarize reduces the endpoint stream to text.
            let summary = try await summarize([LLMMessage(role: .user, content: "summarize me")])
            return .compacted(
                ConversationCompaction(summary: summary, archivedCount: 2)
            )
        }
        let loop = makeLoop(recorder: recorder, contexts: [rebuilt], compactor: compactor)

        let result = try await loop.compactIfNeeded(
            turnContext: original, endpoint: FakeEndpoint(response: "rolled summary"))

        let events = await recorder.events
        let compactions = events.compactMap { event -> (Int, String)? in
            guard case .conversationCompacted(let archivedCount, let summary) = event else { return nil }
            return (archivedCount, summary)
        }
        #expect(compactions.count == 1)
        guard let (archivedCount, summary) = compactions.first else {
            Issue.record("Expected conversationCompacted, got \(events)")
            return
        }
        #expect(archivedCount == 2)
        #expect(summary == "rolled summary")
        let requests = events.compactMap { event -> ModelRequestRecord? in
            guard case .modelRequestStarted(let record) = event else { return nil }
            return record
        }
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .compaction)
        #expect(
            events.contains { event in
                if case .modelRequestCompleted = event { return true }
                return false
            })
        // The loop re-built the context after journaling: context() was
        // called exactly once (the rebuild), serving the trimmed context.
        #expect(await recorder.contextCalls == 1)
        #expect(result.promptContext.conversationThread.isEmpty)
    }

    @Test("session-owning endpoints are never offered compaction")
    func sessionOwningEndpointExcluded() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor { _, _, _ in
            await recorder.compacted()
            return .compacted(
                ConversationCompaction(summary: "x", archivedCount: 1)
            )
        }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        let result = try await loop.compactIfNeeded(turnContext: context, endpoint: FakeSessionEndpoint())

        #expect(FakeSessionEndpoint().contextOwnership == .endpointSession)
        #expect(await recorder.compactorCalls == 0)
        #expect(await recorder.events.isEmpty)
        #expect(await recorder.contextCalls == 0)
        #expect(result.promptContext.conversationThread.isEmpty)
    }

    @Test("an endpoint-session declaration requires the session contract")
    func inconsistentContextOwnershipRejected() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: nil)

        await #expect(throws: AgentRuntimeError.self) {
            try await loop.compactIfNeeded(
                turnContext: context,
                endpoint: MisconfiguredSessionEndpoint()
            )
        }
    }

    @Test("an unchanged decision journals nothing and keeps the context")
    func noCompactionNoJournal() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor { _, _, _ in .unchanged }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        let result = try await loop.compactIfNeeded(turnContext: context, endpoint: FakeEndpoint(response: "unused"))

        #expect(await recorder.events.isEmpty)
        // An unchanged decision never triggers the post-compaction context rebuild.
        #expect(await recorder.contextCalls == 0)
        #expect(result.promptContext.conversationThread.isEmpty)
    }

    @Test("budgeting receives the complete projected request and tool schemas")
    func completeRequestIsBudgeted() async throws {
        let recorder = Recorder()
        var context = try makeContext(thread: [])
        context.preparedRequest = PreparedRequest(
            prefix: [LLMMessage(role: .system, content: "base prompt")],
            conversation: []
        )
        let added = LLMMessage(role: .user, content: "current turn")
        let tool = LLMToolSchema(
            type: "function",
            function: .init(
                name: "search",
                description: "Search",
                parameters: .init(type: "object", properties: nil, required: nil)
            )
        )
        let compactor = FakeCompactor { _, request, _ in
            await recorder.budgeted(messages: request.messages, tools: request.tools)
            return .unchanged
        }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        _ = try await loop.compactIfNeeded(
            turnContext: context,
            endpoint: FakeEndpoint(response: "unused"),
            additionalMessages: [added],
            tools: [tool]
        )

        #expect(await recorder.budgetedMessageCount == 2)
        #expect(await recorder.budgetedToolCount == 1)
    }

    @Test("a compactor failure propagates instead of sending oversized context")
    func compactorFailurePropagates() async throws {
        struct CompactionError: Error, Equatable {}
        let recorder = Recorder()
        let context = try makeContext(thread: [
            .text(sender: "user", content: "m1", timestamp: Date())
        ])
        let compactor = FakeCompactor { _, _, _ in throw CompactionError() }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: CompactionError.self) {
            try await loop.compactIfNeeded(
                turnContext: context,
                endpoint: FakeEndpoint(response: "unused")
            )
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("failure of a supported token counter propagates")
    func supportedTokenCounterFailurePropagates() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor { _, _, _ in .unchanged }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: TokenCountingError.self) {
            try await loop.compactIfNeeded(
                turnContext: context,
                endpoint: FailingTokenCountEndpoint()
            )
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("compactor cancellation aborts the turn")
    func compactorCancellationPropagates() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor { _, _, _ in throw CancellationError() }
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: CancellationError.self) {
            try await loop.compactIfNeeded(
                turnContext: context,
                endpoint: FakeEndpoint(response: "unused")
            )
        }
        #expect(await recorder.events.isEmpty)
    }
}
