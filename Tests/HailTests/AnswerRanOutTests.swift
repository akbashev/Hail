import AnyLanguageModel
import DistributedCluster
import HailCore
import Synchronization
import Testing

@testable import HailAgentRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A model whose answer ran out while it was thinking, after the tools it called answered, is told
/// so, in the journal, and asked again from it: the tools aren't run again, and the turn answers.
@Suite("An answer that ran out")
struct AnswerRanOutTests {
    let agentID = AgentID(role: Role("tester"), contextID: AgentContextID("ran-out"))

    @Test("the model is told, in the journal, and goes on from its tools' results")
    func theTurnGoesOnFromTheResults() async throws {
        let journal = Journal()
        let model = RunsOutOnce()
        let definition = try AgentDefinition(role: agentID.role, behavior: .init(systemPrompt: "sys"))
        let context: @Sendable () async -> TurnContext = { [agentID] in
            let promptContext = PromptContext(
                agentID: agentID, definition: definition,
                modelConfiguration: ModelConfiguration(model: try! AgentModel("test/fake")),
                history: await journal.history, contextManifest: ContextManifest(items: []),
                instructions: PromptAssemblyInstructions(task: "Rules: test."))
            return TurnContext(
                preparedRequest: assembleStandardPrompt(promptContext), promptContext: promptContext)
        }
        let loop = ReasoningLoop(
            agentID: agentID, authority: FullAuthority(),
            context: { await context() }, rebuildContext: { _ in await context() },
            endpoint: { _ in model }, session: { _ in AgentSession() },
            emit: { event in await journal.record(event) }, recordActivity: { _ in },
            clock: ContinuousClock(), maxToolRounds: 8)

        let system = await ClusterSystem("answer-ran-out") { $0.bindPort = Int.random(in: 30_000...40_000) }
        defer { try? system.shutdown() }
        let connection = AgentConnection<String>(actorSystem: system) { _ in }
        try await loop.run(
            "weather",
            opening: .received(.init(content: GeneratedContent("weather"), at: Date())),
            inputID: nil, through: connection)

        let steps = await journal.events.compactMap { event -> String? in
            guard case .history(let history) = event else { return nil }
            switch history {
            case .received: return "received"
            case .called: return "called"
            case .resulted: return "resulted"
            case .noticed(.answerRanOut, _): return "noticed"
            case .replied(let reply): return "replied \(reply.content.textValue ?? "")"
            case .failed: return "failed"
            default: return nil
            }
        }
        #expect(steps == ["received", "called", "resulted", "noticed", "replied It's sunny."])
        // The second request goes on from the journal: the call, its result, and the notice last.
        let asked = model.requests.withLock { $0 }
        #expect(asked.count == 2)
        let second = try #require(asked.last)
        #expect(second.entries.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(second.entries.contains { if case .toolOutput = $0 { true } else { false } })
        guard case .prompt(let prompt)? = second.entries.last else {
            Issue.record("The second request doesn't end with the notice")
            return
        }
        #expect(prompt.segments.description.contains("your answer ran out while you were thinking"))
        #expect(second.reasoning == .disabled)
    }
}

/// The agent's journal: its events, and the history they make.
private actor Journal {
    private(set) var events: [AgentEvent] = []
    private(set) var history = AgentHistory()

    func record(_ event: AgentEvent) {
        events.append(event)
        if case .history(let step) = event { history = (try? history.applying(step)) ?? history }
    }
}

/// A model that calls a tool and then writes nothing, the first time; told so, it answers.
private final class RunsOutOnce: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384
    let requests = Mutex<[(entries: [Transcript.Entry], reasoning: ModelReasoningOverride)]>([])

    func stream<Input: Sendable, Output: Codable & Sendable & Generable>(
        request: ModelRequest<Input>, tools: [AnyTool], authority: any Authority, generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>> where Output.PartiallyGenerated: Sendable {
        let attempt = requests.withLock { requests in
            requests.append((request.entries, request.reasoning))
            return requests.count
        }
        return AsyncStream { continuation in
            Task {
                if attempt == 1 {
                    let (reply, answer) = ToolReply.awaiting()
                    continuation.yield(
                        .toolCall(
                            ModelToolCall(
                                call: ToolCall(
                                    id: "call-1", name: "weather", arguments: GeneratedContent(properties: [:])),
                                reply: reply)))
                    _ = await answer.first { _ in true }
                    continuation.yield(.failed(.thoughtPastAnswer))
                } else {
                    continuation.yield(.generated(try! Output(GeneratedContent("It's sunny."))))
                }
                continuation.finish()
            }
        }
    }
}

extension GeneratedContent {
    fileprivate var textValue: String? {
        if case .string(let text) = kind { return text }
        return nil
    }
}
