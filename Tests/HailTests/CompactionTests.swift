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
            state.apply(.messageReceived(message("m\(i)", TimeInterval(i))))
        }
        return state
    }

    @Test("conversationCompacted installs the summary and trims the prefix")
    func foldTrimsPrefixAndInstallsSummary() {
        var state = state(threadCount: 5)
        state.apply(.conversationCompacted(archivedCount: 3, summary: "first three messages"))
        #expect(state.contextSummary == "first three messages")
        #expect(state.conversationThread.count == 2)
        #expect(
            state.conversationThread.compactMap { message in
                guard case .text(_, let content, _) = message else { return nil }
                return content
            } == ["m3", "m4"]
        )
    }

    @Test("assistant narration accompanying a tool call survives replay")
    func assistantToolNarrationIsRetained() {
        var state = AgentState(agentID: agentID)
        let call = ToolCall(id: "call-read", name: "read_file", arguments: .empty)
        state.apply(
            .assistantToolRound(
                content: "I will inspect the file first.",
                thinking: nil,
                calls: [call],
                at: Date(timeIntervalSince1970: 1)
            )
        )
        guard case .assistantToolCall(let content, _, _, _) = state.conversationThread.first else {
            Issue.record("Expected assistant narration in the replayed thread")
            return
        }
        #expect(content == "I will inspect the file first.")
    }

    @Test("a second compaction replaces the summary — the fold is rolling")
    func secondCompactionReplacesSummary() {
        var state = state(threadCount: 5)
        state.apply(.conversationCompacted(archivedCount: 3, summary: "v1"))
        state.apply(.conversationCompacted(archivedCount: 1, summary: "v2 folds v1"))
        #expect(state.contextSummary == "v2 folds v1")
        #expect(state.conversationThread.count == 1)
        #expect(
            state.conversationThread.compactMap { message in
                guard case .text(_, let content, _) = message else { return nil }
                return content
            } == ["m4"]
        )
    }

    @Test("archivedCount beyond the thread length is ignored")
    func outOfBoundsArchiveCountIgnored() {
        var state = state(threadCount: 2)
        state.apply(.conversationCompacted(archivedCount: 10, summary: "over"))
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
                    model: try AgentModel("test/fake")
                ),
            ),
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

    @Test("assistant tool rounds replay as one provider message")
    func assistantToolRoundIsReplayedAsOneMessage() throws {
        let call = ToolCall(
            id: "call-now",
            name: "now",
            arguments: .empty
        )
        let thread: [ChatMessage] = [
            .assistantToolCall(
                content: "I’ll check the time.",
                thinking: "The user asked for the current time.",
                calls: [call],
                timestamp: Date(timeIntervalSince1970: 1)
            )
        ]

        let messages = assembleStandardPrompt(
            try context(summary: nil, thread: thread)
        ).messages

        guard let replay = messages.last else {
            Issue.record("Expected the assistant tool round in the prompt")
            return
        }
        #expect(replay.role == .assistant)
        #expect(replay.content == "I’ll check the time.")
        #expect(replay.thinking == "The user asked for the current time.")
        #expect(replay.toolCalls?.count == 1)
        #expect(replay.toolCalls?.first?.id == "call-now")
        #expect(replay.toolCalls?.first?.function.name == "now")
        #expect(replay.toolCalls?.first?.function.arguments == "{}")
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
/// journaling, context rebuild, and failure propagation.
@Suite("ReasoningLoop compaction")
struct ReasoningLoopCompactionTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("c1"))

    // MARK: Fakes

    private struct FakeEndpoint: ModelEndpoint {
        let model = "fake"
        let contextOwnership: ModelContextOwnership = .runtime
        let effectiveContextWindow: Int? = 4_096
        let response: String

        func stream(
            input: ModelInput,
            tools: [ToolDefinition]?
        ) -> AsyncStream<ModelEvent<String>> {
            let response = self.response
            return AsyncStream { continuation in
                continuation.yield(.text(response))
                continuation.yield(.generated(response))
                continuation.finish()
            }
        }
    }

    private struct FailingTokenCountEndpoint: ModelEndpoint {
        let model = "counting-fails"
        let contextOwnership: ModelContextOwnership = .runtime
        let effectiveContextWindow: Int? = 4_096
        let tokenCounting: TokenCounting = .available {
            (_: [LLMMessage], _: [ToolDefinition]) async throws(AgentRuntimeError) -> Int in
            throw AgentRuntimeError.infrastructureFailure("tokenizer unavailable")
        }

        func stream(
            input: ModelInput,
            tools: [ToolDefinition]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }
    }

    private struct RichCountingEndpoint: ModelEndpoint {
        let model = "rich-counting"
        let contextOwnership: ModelContextOwnership = .runtime
        let effectiveContextWindow: Int? = 4_096
        let tokenCounting: TokenCounting = .availableInput { input, _ in
            input.containsUnsupportedData ? 512 : 0
        }

        func stream(
            input: ModelInput,
            tools: [ToolDefinition]?
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
            input: ModelInput,
            tools: [ToolDefinition]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }

        func stream<T: AgentOutput>(
            input: ModelInput,
            delta: TurnDelta,
            authority: any Authority,
            tools: [ToolDefinition]?,
            responseType: T.Type
        ) -> AsyncStream<ModelEvent<T>> {
            AsyncStream { $0.finish() }
        }
    }

    private struct MisconfiguredSessionEndpoint: ModelEndpoint {
        let model = "misconfigured-session"
        let contextOwnership: ModelContextOwnership = .endpointSession

        func stream(
            input: ModelInput,
            tools: [ToolDefinition]?
        ) -> AsyncStream<ModelEvent<String>> {
            AsyncStream { $0.finish() }
        }
    }

    private struct FakeCompactor: ContextCompactor {
        typealias Body =
            @Sendable (
                PromptContext,
                PreparedRequest,
                CompactionBudget,
                @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String
            ) async throws(AgentRuntimeError) -> CompactionDecision

        let body: Body
        let recordMeasurement: (@Sendable (RequestMeasurement?) async -> Void)?

        init(
            body: @escaping Body,
            recordMeasurement: (@Sendable (RequestMeasurement?) async -> Void)? = nil
        ) {
            self.body = body
            self.recordMeasurement = recordMeasurement
        }

        func compact(
            context: PromptContext,
            request: PreparedRequest,
            budget: CompactionBudget,
            measurement: RequestMeasurement?,
            measure: RequestMeasurer?,
            assemble: PromptAssembler,
            summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> String,
            trigger: ContextCompactionTrigger
        ) async throws(AgentRuntimeError) -> CompactionDecision {
            await recordMeasurement?(measurement)
            return try await body(context, request, budget, summarize)
        }
    }

    private actor Recorder {
        var events: [AgentEvent] = []
        var contextCalls = 0
        var compactorCalls = 0
        var budgetedMessageCount = 0
        var budgetedToolCount = 0
        var measuredTokenCount: Int?
        var rebuiltManifestItems: [ContextItem]?
        var rebuiltInstructions: PromptAssemblyInstructions?

        func record(_ event: AgentEvent) { events.append(event) }
        func nextContext() -> Int {
            contextCalls += 1
            return contextCalls
        }
        func compacted() { compactorCalls += 1 }
        func budgeted(messages: [LLMMessage], tools: [ToolDefinition]) {
            budgetedMessageCount = messages.count
            budgetedToolCount = tools.count
        }
        func measured(_ measurement: RequestMeasurement?) {
            measuredTokenCount = measurement?.tokenCount
        }
        func recordRebuildSnapshot(_ context: TurnContext) {
            rebuiltManifestItems = context.promptContext.contextManifest.items
            rebuiltInstructions = context.promptContext.instructions
        }
    }

    // MARK: Helpers

    private func makeContext(
        thread: [ChatMessage],
        manifest: ContextManifest = ContextManifest(items: []),
        instructions: PromptAssemblyInstructions = PromptAssemblyInstructions()
    ) throws -> TurnContext {
        let promptContext = PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModel("test/fake")
                ),
            ),
            conversationThread: thread,
            contextManifest: manifest,
            instructions: instructions
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
            sessionIdentity: SessionIdentity(rawValue: "identity"),
            modelSession: nil
        )
    }

    private func makeLoop(
        recorder: Recorder,
        contexts: [TurnContext],
        compactor: (any ContextCompactor)?,
        rebuildContext: (@Sendable (TurnContext) async throws(AgentRuntimeError) -> TurnContext)? = nil
    ) -> ReasoningLoop<ContinuousClock> {
        final class Index: @unchecked Sendable { var value = 0 }
        let index = Index()
        let rebuild =
            rebuildContext ?? { (_: TurnContext) async throws(AgentRuntimeError) -> TurnContext in
                let i = min(index.value, contexts.count - 1)
                index.value += 1
                _ = await recorder.nextContext()
                return contexts[i]
            }
        return ReasoningLoop<ContinuousClock>(
            agentID: agentID,
            authority: FullAuthority(),
            context: {
                let i = min(index.value, contexts.count - 1)
                index.value += 1
                _ = await recorder.nextContext()
                return contexts[i]
            },
            rebuildContext: rebuild,
            endpoint: { FakeEndpoint(response: "rolled summary") },
            tools: { _ in ToolRegistry(authority: FullAuthority()) },
            emit: { await recorder.record($0) },
            recordActivity: { _ in },
            compactor: compactor,
            clock: ContinuousClock(),
            maxToolRounds: 25
        )
    }

    // MARK: Tests

    @Test("a compaction result is journaled atomically and the context rebuilt")
    func compactionJournaledAndContextRebuilt() async throws {
        let recorder = Recorder()
        let original = try makeContext(
            thread: [
                .text(sender: "user", content: "m1", timestamp: Date()),
                .text(sender: "user", content: "m2", timestamp: Date()),
            ], manifest: ContextManifest(items: [.inline(text: "stable context")]),
            instructions: PromptAssemblyInstructions(interactive: "stable instruction"))
        let rebuilt = try makeContext(
            thread: [],
            manifest: original.promptContext.contextManifest,
            instructions: original.promptContext.instructions
        )
        let body: FakeCompactor.Body = { _, _, _, summarize in
            await recorder.compacted()
            // The runtime's summarize reduces the endpoint stream to text.
            let summary = try await summarize(
                CompactionSummaryRequest(
                    messages: [LLMMessage(role: .user, content: "summarize me")],
                    maxOutputTokens: 4_096
                )
            )
            return .compacted(
                ConversationCompaction(summary: summary, archivedCount: 2)
            )
        }
        let compactor = FakeCompactor(body: body)
        let loop = makeLoop(
            recorder: recorder,
            contexts: [rebuilt],
            compactor: compactor,
            rebuildContext: { snapshot in
                await recorder.recordRebuildSnapshot(snapshot)
                _ = await recorder.nextContext()
                return rebuilt
            }
        )

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
        #expect(await recorder.rebuiltManifestItems == original.promptContext.contextManifest.items)
        #expect(await recorder.rebuiltInstructions == original.promptContext.instructions)
        #expect(result.promptContext.conversationThread.isEmpty)
    }

    @Test("session-owning endpoints are never offered compaction")
    func sessionOwningEndpointExcluded() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor(body: { _, _, _, _ in
            await recorder.compacted()
            return .compacted(
                ConversationCompaction(summary: "x", archivedCount: 1)
            )
        })
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
        let compactor = FakeCompactor(body: { _, _, _, _ in .unchanged })
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
        let tool = TestToolDefinition.empty(name: "search", description: "Search")
        let compactor = FakeCompactor(body: { _, request, _, _ in
            await recorder.budgeted(messages: request.messages, tools: request.tools)
            return .unchanged
        })
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

    @Test("provider-aware counting can inspect rich tool output")
    func richToolOutputIsBudgeted() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [])
        let compactor = FakeCompactor(
            body: { _, _, _, _ in .unchanged },
            recordMeasurement: { measurement in
                await recorder.measured(measurement)
            }
        )
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)
        var input = ModelInput(messages: [])
        input.appendToolOutput(
            callID: "fetch-1",
            name: "fetch",
            output: .data(
                ToolData(
                    body: Data(repeating: 1, count: 2048),
                    contentType: "application/octet-stream"
                )
            )
        )

        _ = try await loop.compactIfNeeded(
            turnContext: context,
            endpoint: RichCountingEndpoint(),
            requestInput: input
        )

        #expect(await recorder.measuredTokenCount == 512)
    }

    @Test("compaction does not reintroduce archived rich tool output")
    func archivedRichToolOutputIsDroppedFromCandidateInput() {
        let toolMessage = LLMMessage(
            role: .tool,
            content: "image metadata",
            toolCallID: "fetch-1"
        )
        var input = ModelInput(messages: [])
        input.appendToolOutput(
            callID: "fetch-1",
            name: "fetch",
            output: .data(
                ToolData(
                    body: Data(repeating: 1, count: 2_048),
                    contentType: "image/jpeg"
                )
            )
        )

        let source = PreparedRequest(
            prefix: [],
            conversation: [
                PreparedRequest.ConversationEntry(sourceIndex: 0, message: toolMessage)
            ],
            input: input
        )
        let live = PreparedRequest(prefix: [], conversation: [], input: input)

        #expect(source.input(for: []).entries.isEmpty)
        #expect(live.input(for: []).entries.count == 1)
    }

    @Test("a compactor failure propagates instead of sending oversized context")
    func compactorFailurePropagates() async throws {
        let recorder = Recorder()
        let context = try makeContext(thread: [
            .text(sender: "user", content: "m1", timestamp: Date())
        ])
        let body: FakeCompactor.Body = {
            _, _, _, _ in throw AgentRuntimeError.infrastructureFailure("compactor unavailable")
        }
        let compactor = FakeCompactor(body: body)
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: AgentRuntimeError.infrastructureFailure("compactor unavailable")) {
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
        let compactor = FakeCompactor(body: { _, _, _, _ in .unchanged })
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: AgentRuntimeError.infrastructureFailure("tokenizer unavailable")) {
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
        let body: FakeCompactor.Body = { _, _, _, _ in throw AgentRuntimeError.cancelled }
        let compactor = FakeCompactor(body: body)
        let loop = makeLoop(recorder: recorder, contexts: [context], compactor: compactor)

        await #expect(throws: AgentRuntimeError.cancelled) {
            try await loop.compactIfNeeded(
                turnContext: context,
                endpoint: FakeEndpoint(response: "unused")
            )
        }
        #expect(await recorder.events.isEmpty)
    }
}
