import AnyLanguageModel
import HailCore
import Testing

@testable import HailAgentRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Compaction trigger")
struct CompactionTriggerTests {
    @Test("a reported floor at the window is offered as the trigger measurement")
    func reportedFloorAtWindowIsOffered() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 12_000, limitTokens: 16_384, source: .reported),
            window: 16_384
        )
        #expect(measurement?.tokenCount == 12_000)
        #expect(measurement?.source == .reported)
    }

    @Test("a missing report yields no floor")
    func missingUsageYieldsNoFloor() {
        #expect(
            ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(usage: nil, window: 100)
                == nil
        )
    }

    @Test("a report against a different window is not trusted")
    func mismatchedWindowYieldsNoFloor() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 90, limitTokens: 100, source: .reported),
            window: 16_384
        )
        #expect(measurement == nil)
    }

    @Test("a zero-usage report yields no floor")
    func zeroUsageYieldsNoFloor() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 0, limitTokens: 16_384, source: .reported),
            window: 16_384
        )
        #expect(measurement == nil)
    }
}

/// Policy for compactor and summarizer failures: a `.threshold` failure is
/// auxiliary and must not fail the turn, while a `.contextLengthExceeded`
/// failure propagates because the request is known not to fit.
@Suite("Compaction failure policy")
struct CompactionFailurePolicyTests {
    private let agentID = AgentID(role: Role("coder"), contextID: AgentContextID("conversation"))

    /// A compactor whose summarizer always fails, letting the test exercise
    /// the runtime's failure policy without a model.
    private struct ThrowingCompactor: ContextCompactor {
        func compact<Output: Codable & Sendable & Generable>(
            context: PromptContext,
            request: PreparedRequest,
            budget: CompactionBudget,
            measurement: RequestMeasurement?,
            measure: RequestMeasurer?,
            assemble: PromptAssembler,
            summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
            contextProjection: @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError)
                -> GeneratedContent,
            trigger: ContextCompactionTrigger
        ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
            throw AgentRuntimeError.modelMisbehavior("summarizer exploded")
        }
    }

    /// A runtime-owned endpoint without a token counter; the summarizer is
    /// never reached, so the stream stays unfinished.
    private struct StubEndpoint: ModelEndpoint {
        let model = "test/fake"
        let contextOwnership: ModelContextOwnership = .runtime
        let effectiveContextWindow: Int? = 16_384
        let tokenCounting: TokenCounting = .unavailable

        func stream<Input: Sendable, Output: Codable & Sendable & Generable>(
            request: ModelRequest<Input>,
            tools: [AnyTool],
            authority: any Authority,
            generating: Output.Type,
            purpose: ModelRequestPurpose
        ) -> AsyncStream<ModelEvent<Output>> where Output.PartiallyGenerated: Sendable {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
    }

    private actor EventLog {
        private(set) var events: [AgentEvent] = []
        func append(_ event: AgentEvent) {
            events.append(event)
        }
    }

    private func message(_ content: String, at offset: TimeInterval) -> ChatMessage {
        .text(
            sender: "user",
            content: content,
            timestamp: Date(timeIntervalSince1970: offset)
        )
    }

    private func definition() throws -> AgentDefinition {
        try AgentDefinition(
            role: agentID.role,
            behavior: .init(
                systemPrompt: "sys",
                model: AgentModel("test/fake")
            )
        )
    }

    private func instructions() -> PromptAssemblyInstructions {
        PromptAssemblyInstructions(task: "Rules: test.")
    }

    private func turnContext(definition: AgentDefinition) -> TurnContext {
        let promptContext = PromptContext(
            agentID: agentID,
            definition: definition,
            contextSummary: nil,
            conversationThread: [
                message("one", at: 1),
                message("two", at: 2),
                message("three", at: 3),
            ],
            contextManifest: ContextManifest(items: []),
            instructions: instructions()
        )
        var turnContext = TurnContext(
            preparedRequest: assembleStandardPrompt(promptContext),
            promptContext: promptContext,
            sessionIdentity: SessionIdentity("test-session"),
            modelSession: nil
        )
        // Above the compactor's 0.7 threshold, so a threshold pass is offered
        // even without a token counter.
        turnContext.latestContextUsage = ContextUsage(
            usedTokens: 12_000,
            limitTokens: 16_384,
            source: .reported
        )
        return turnContext
    }

    private func makeLoop(
        definition: AgentDefinition,
        events: EventLog,
        compactor: any ContextCompactor
    ) -> ReasoningLoop<ContinuousClock> {
        ReasoningLoop(
            agentID: agentID,
            authority: FullAuthority(),
            context: { [agentID] in
                let promptContext = PromptContext(
                    agentID: agentID,
                    definition: definition,
                    contextSummary: nil,
                    conversationThread: [],
                    contextManifest: ContextManifest(items: []),
                    instructions: PromptAssemblyInstructions(task: "Rules: test.")
                )
                return TurnContext(
                    preparedRequest: assembleStandardPrompt(promptContext),
                    promptContext: promptContext,
                    sessionIdentity: SessionIdentity("test-session"),
                    modelSession: nil
                )
            },
            rebuildContext: { $0 },
            endpoint: { StubEndpoint() },
            tools: { _ in ToolRegistry() },
            emit: { event in
                await events.append(event)
            },
            recordActivity: { _ in },
            compactor: compactor,
            clock: ContinuousClock(),
            maxToolRounds: 8
        )
    }

    @Test("a threshold-triggered compaction failure continues the turn un-compacted")
    func thresholdFailureContinuesTurn() async throws {
        let definition = try definition()
        let events = EventLog()
        let loop = makeLoop(definition: definition, events: events, compactor: ThrowingCompactor())
        let turnContext = turnContext(definition: definition)

        let returned = try await loop.compactIfNeeded(
            turnContext: turnContext,
            endpoint: StubEndpoint()
        )

        #expect(returned.promptContext.conversationThread == turnContext.promptContext.conversationThread)
        #expect(returned.preparedRequest.entries == turnContext.preparedRequest.entries)
        let recorded = await events.events
        #expect(!recorded.contains { event in
            if case .conversationCompacted = event {
                return true
            }
            return false
        })
    }

    @Test("a recovery-triggered compaction failure still fails the request")
    func recoveryFailurePropagates() async throws {
        let definition = try definition()
        let events = EventLog()
        let loop = makeLoop(definition: definition, events: events, compactor: ThrowingCompactor())
        let turnContext = turnContext(definition: definition)

        do {
            _ = try await loop.compactIfNeeded(
                turnContext: turnContext,
                endpoint: StubEndpoint(),
                trigger: .contextLengthExceeded
            )
            Issue.record("Expected the recovery compaction failure to propagate")
        } catch AgentRuntimeError.modelMisbehavior(let reason) {
            #expect(reason == "summarizer exploded")
        }
    }
}
