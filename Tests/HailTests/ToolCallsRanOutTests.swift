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

/// A turn that made all the tool calls it may make is told so, in the journal, and asked once more
/// from it, offered no tools: it answers with where the work stands.
@Suite("Tool calls that ran out")
struct ToolCallsRanOutTests {
    let agentID = AgentID(role: Role("tester"), contextID: AgentContextID("calls-ran-out"))

    @Test("the model is told, in the journal, and answers without tools")
    func theTurnAnswersWithoutTools() async throws {
        let journal = Journal()
        let model = CallsPastTheLimit()
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
            clock: ContinuousClock(), maxToolRounds: 2)

        let system = await ClusterSystem("calls-ran-out") { $0.bindPort = Int.random(in: 30_000...40_000) }
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
            case .noticed(.toolCallsRanOut(let limit), _): return "noticed \(limit)"
            case .replied(let reply): return "replied \(reply.content.textValue ?? "")"
            case .failed: return "failed"
            default: return nil
            }
        }
        #expect(
            steps == [
                "received", "called", "resulted", "called", "resulted", "noticed 2", "replied Two of three done.",
            ])
        let asked = model.requests.withLock { $0 }
        #expect(asked.count == 2)
        let second = try #require(asked.last)
        #expect(second.tools == 0)
        guard case .prompt(let prompt)? = second.entries.last else {
            Issue.record("The second request doesn't end with the notice")
            return
        }
        #expect(prompt.segments.description.contains("this turn has made all 2 of its tool calls"))
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

/// A model that calls three tools the first time, one past the limit; told so, it answers.
private final class CallsPastTheLimit: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384
    let requests = Mutex<[(entries: [Transcript.Entry], tools: Int)]>([])

    func stream<Input: Sendable, Output: Codable & Sendable & Generable>(
        request: ModelRequest<Input>, tools: [AnyTool], authority: any Authority, generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>> where Output.PartiallyGenerated: Sendable {
        let attempt = requests.withLock { requests in
            requests.append((request.entries, tools.count))
            return requests.count
        }
        return AsyncStream { continuation in
            Task {
                if attempt == 1 {
                    for index in 1...3 {
                        let (reply, answer) = ToolReply.awaiting()
                        continuation.yield(
                            .toolCall(
                                ModelToolCall(
                                    call: ToolCall(
                                        id: "call-\(index)", name: "weather-\(index)",
                                        arguments: GeneratedContent(properties: [:])), reply: reply)))
                        _ = await answer.first { _ in true }
                    }
                } else {
                    continuation.yield(.generated(try! Output(GeneratedContent("Two of three done."))))
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
