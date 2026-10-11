import AnyLanguageModel
import HailCore
import Testing
import Synchronization

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
            measuring: RequestMeasuring,
            assemble: PromptAssembler,
            summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
            contextProjection:
                @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError)
                -> GeneratedContent,
            trigger: ContextCompactionTrigger
        ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
            throw AgentRuntimeError.modelMisbehavior("summarizer exploded")
        }
    }

    /// A compactor that records the triggers it's asked with, and leaves the context as it is.
    private final class RecordingCompactor: ContextCompactor, Sendable {
        let triggers = Mutex<[ContextCompactionTrigger]>([])

        func compact<Output: Codable & Sendable & Generable>(
            context: PromptContext,
            request: PreparedRequest,
            budget: CompactionBudget,
            measuring: RequestMeasuring,
            assemble: PromptAssembler,
            summarize: @Sendable (CompactionSummaryRequest) async throws(AgentRuntimeError) -> Output,
            contextProjection:
                @Sendable (Output, ContextProjectionBudget) throws(AgentRuntimeError)
                -> GeneratedContent,
            trigger: ContextCompactionTrigger
        ) async throws(AgentRuntimeError) -> CompactionDecision<Output> {
            triggers.withLock { $0.append(trigger) }
            return .unchanged
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

    private func history(_ said: [String]) throws -> AgentHistory {
        try said.enumerated().reduce(AgentHistory()) { history, next in
            let at = Date(timeIntervalSince1970: TimeInterval(next.offset))
            return try history
                .applying(.received(.init(from: .user(id: "u"), content: GeneratedContent(next.element), at: at), turn: TurnID()))
                .applying(.replied(.init(content: GeneratedContent("ok"), at: at)))
        }
    }

    private func definition() throws -> AgentDefinition {
        try AgentDefinition(
            role: agentID.role,
            behavior: .init(
                systemPrompt: "sys"
            )
        )
    }

    private func instructions() -> PromptAssemblyInstructions {
        PromptAssemblyInstructions(task: "Rules: test.")
    }

    private func turnContext(definition: AgentDefinition) throws -> TurnContext {
        let promptContext = PromptContext(
            agentID: agentID,
            definition: definition,
            modelConfiguration: ModelConfiguration(model: try! AgentModel("test/fake")),
            history: try history(["one", "two", "three"]),
            contextManifest: ContextManifest(items: []),
            instructions: instructions()
        )
        var turnContext = TurnContext(
            preparedRequest: assembleStandardPrompt(promptContext),
            promptContext: promptContext,
            sessionIdentity: SessionIdentity("test-session"),
            modelSession: nil
        )
        // Above the compactor's 0.8 threshold, so a threshold pass is offered
        // even without a token counter.
        turnContext.latestContextUsage = ContextUsage(
            usedTokens: 14_000,
            limitTokens: 16_384,
            source: .reported
        )
        return turnContext
    }

    private func makeLoop(
        definition: AgentDefinition,
        events: EventLog,
        compactor: any ContextCompactor,
        reported: ContextUsage? = nil
    ) -> ReasoningLoop<ContinuousClock> {
        ReasoningLoop(
            agentID: agentID,
            authority: FullAuthority(),
            context: { [agentID] in
                let promptContext = PromptContext(
                    agentID: agentID,
                    definition: definition,
                    modelConfiguration: ModelConfiguration(model: try! AgentModel("test/fake")),
                    history: AgentHistory(),
                    contextManifest: ContextManifest(items: []),
                    instructions: PromptAssemblyInstructions(task: "Rules: test.")
                )
                var turnContext = TurnContext(
                    preparedRequest: assembleStandardPrompt(promptContext),
                    promptContext: promptContext,
                    sessionIdentity: SessionIdentity("test-session"),
                    modelSession: nil
                )
                turnContext.latestContextUsage = reported
                return turnContext
            },
            rebuildContext: { $0 },
            endpoint: { _ in StubEndpoint() },
            session: { _ in AgentSession() },
            emit: { event in
                await events.append(event)
            },
            recordActivity: { _ in },
            compactor: compactor,
            clock: ContinuousClock(),
            maxToolRounds: 8
        )
    }

    @Test("after a turn, a context the last request reported past the threshold is offered compaction")
    func compactsAfterTheTurn() async throws {
        let compactor = RecordingCompactor()
        let loop = makeLoop(
            definition: try definition(), events: EventLog(), compactor: compactor,
            reported: ContextUsage(usedTokens: 14_000, limitTokens: 16_384, source: .reported))

        await loop.compactAfterTurn()

        #expect(compactor.triggers.withLock { $0 } == [.threshold])
    }

    @Test("a threshold-triggered compaction failure continues the turn un-compacted")
    func thresholdFailureContinuesTurn() async throws {
        let definition = try definition()
        let events = EventLog()
        let loop = makeLoop(definition: definition, events: events, compactor: ThrowingCompactor())
        let turnContext = try turnContext(definition: definition)

        let returned = try await loop.compactIfNeeded(
            turnContext: turnContext,
            endpoint: StubEndpoint()
        )

        #expect(returned.promptContext.history == turnContext.promptContext.history)
        #expect(returned.preparedRequest.entries == turnContext.preparedRequest.entries)
        let recorded = await events.events
        #expect(
            !recorded.contains { event in
                if case .history(.compacted) = event {
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
        let turnContext = try turnContext(definition: definition)

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
