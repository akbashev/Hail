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

/// A model that answers, but not in the form asked for, is told so in the journal, with what it
/// wrote, and asked again: the turn answers, or, when it keeps doing so, fails saying why.
@Suite("An answer out of shape")
struct AnswerOutOfShapeTests {
    let agentID = AgentID(role: Role("tester"), contextID: AgentContextID("out-of-shape"))

    private func run(_ model: OutOfShape) async throws -> (steps: [String], requests: [[Transcript.Entry]]) {
        let journal = Journal()
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

        let system = await ClusterSystem("answer-out-of-shape") { $0.bindPort = Int.random(in: 30_000...40_000) }
        defer { try? system.shutdown() }
        let connection = AgentConnection<String>(actorSystem: system) { _ in }
        do {
            try await loop.run(
                "weather",
                opening: .received(.init(content: GeneratedContent("weather"), at: Date())),
                through: connection)
        } catch {}
        let steps = await journal.events.compactMap { event -> String? in
            guard case .history(let history) = event else { return nil }
            switch history {
            case .received: return "received"
            case .noticed(.answerOutOfShape(let written), _): return "noticed \(written)"
            case .replied(let reply): return "replied \(reply.content.textValue ?? "")"
            case .failed(let failure): return "failed \(failure.error)"
            default: return nil
            }
        }
        return (steps, model.requests.withLock { $0 })
    }

    @Test("the model is told, with what it wrote, and answers again")
    func theModelAnswersAgain() async throws {
        let (steps, requests) = try await run(OutOfShape(timesOutOfShape: 1))

        #expect(steps == ["received", "noticed It's sunny.", "replied It's sunny."])
        #expect(requests.count == 2)
        guard case .prompt(let notice)? = requests.last?.last else {
            Issue.record("The second request doesn't end with the notice")
            return
        }
        #expect(notice.segments.description.contains("your answer wasn't in the form asked for"))
        #expect(notice.segments.description.contains("It's sunny."))
    }

    @Test("a model that keeps answering out of shape fails the turn, saying why")
    func aModelThatKeepsAtItFails() async throws {
        let (steps, requests) = try await run(OutOfShape(timesOutOfShape: .max))

        let notices = steps.filter { $0.hasPrefix("noticed") }
        #expect(notices.count == ReasoningLoop<ContinuousClock>.mostAnswersAskedAgainForTheirForm)
        #expect(requests.count == notices.count + 1)
        #expect(steps.last?.contains("modelAnswerOutOfShape") == true)
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

/// A model that answers in prose where a form was asked for, a number of times, then in that form.
private final class OutOfShape: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384
    let timesOutOfShape: Int
    let requests = Mutex<[[Transcript.Entry]]>([])

    init(timesOutOfShape: Int) {
        self.timesOutOfShape = timesOutOfShape
    }

    func stream<Input: Sendable, Output: Codable & Sendable & Generable>(
        request: ModelRequest<Input>, tools: [AnyTool], authority: any Authority, generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>> where Output.PartiallyGenerated: Sendable {
        let attempt = requests.withLock { requests in
            requests.append(request.entries)
            return requests.count
        }
        return AsyncStream { continuation in
            if attempt <= timesOutOfShape {
                continuation.yield(.failed(.answerOutOfShape(written: "It's sunny.")))
            } else {
                continuation.yield(.generated(try! Output(GeneratedContent("It's sunny."))))
            }
            continuation.finish()
        }
    }
}

extension GeneratedContent {
    fileprivate var textValue: String? {
        if case .string(let text) = kind { return text }
        return nil
    }
}
