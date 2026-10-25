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

/// The same call failing the same way twice in a row isn't run a third time, whatever the
/// failure, and the turn goes on: the model answers with what it has.
@Suite("Repeated failures")
struct RepeatedFailureTests {
    let agentID = AgentID(role: Role("tester"), contextID: AgentContextID("repeated-failures"))

    @Test("a call that failed the same way twice isn't run again, and the turn answers")
    func theRepeatedCallIsNotRun() async throws {
        let journal = Journal()
        let runs = Runs()
        let model = CallsTheSameAgain()
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
            endpoint: { _ in model },
            session: { _ in
                var session = AgentSession()
                session.register(tools: [BusyTool(runs: runs)])
                return session
            },
            emit: { event in await journal.record(event) }, recordActivity: { _ in },
            clock: ContinuousClock(), maxToolRounds: 10)

        let system = await ClusterSystem("repeated-failures") { $0.bindPort = Int.random(in: 30_000...40_000) }
        defer { try? system.shutdown() }
        let connection = AgentConnection<String>(actorSystem: system) { _ in }
        try await loop.run(
            "ask",
            opening: .received(.init(content: GeneratedContent("ask"), at: Date())),
            through: connection)

        let steps = await journal.events.compactMap { event -> String? in
            guard case .history(let history) = event else { return nil }
            switch history {
            case .resulted(let result, _): return result.output.textRepresentation
            case .replied(let reply): return "replied \(reply.content.textValue ?? "")"
            case .failed: return "failed"
            default: return nil
            }
        }
        let ann = "Error: Busy with Ann."
        let notRun = "Not run: the same call failed the same way 2 times just before. \(ann)"
        #expect(steps == [ann, ann, notRun, notRun, "Error: Busy with Bob.", "replied Nobody was free."])
        // The calls not run never reached the tool: the same arguments in another order are the
        // same call.
        #expect(runs.count == 3)
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

/// How often the tool ran.
private final class Runs: Sendable {
    private let runs = Mutex(0)
    var count: Int { runs.withLock { $0 } }
    func ran() { runs.withLock { $0 += 1 } }
}

/// Always busy: it fails as a tool that can't be reached for now does, which may clear later.
private struct BusyTool: HailCore.Tool {
    @Generable
    struct Input: Sendable {
        let person: String
        let topic: String
    }

    struct Busy: Error, CustomStringConvertible {
        let person: String
        var description: String { "Busy with \(person)." }
    }

    let runs: Runs
    let name = "ask"
    let description = "Asks someone."

    func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

    func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
        async throws -> CallReturn
    {
        runs.ran()
        throw Busy(person: input.person)
    }
}

/// A model that asks Ann four times, the last time with its arguments in another order, then Bob,
/// then answers.
private final class CallsTheSameAgain: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384

    func stream<Input: Sendable, Output: Codable & Sendable & Generable>(
        request: ModelRequest<Input>, tools: [AnyTool], authority: any Authority, generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>> where Output.PartiallyGenerated: Sendable {
        func asking(_ person: String, reversed: Bool = false) -> GeneratedContent {
            reversed
                ? GeneratedContent(properties: ["topic": "lunch", "person": person])
                : GeneratedContent(properties: ["person": person, "topic": "lunch"])
        }
        let calls = [asking("Ann"), asking("Ann"), asking("Ann"), asking("Ann", reversed: true), asking("Bob")]
        return AsyncStream { continuation in
            Task {
                for (index, arguments) in calls.enumerated() {
                    let (reply, answer) = ToolReply.awaiting()
                    continuation.yield(
                        .toolCall(
                            ModelToolCall(
                                call: ToolCall(id: "call-\(index)", name: "ask", arguments: arguments),
                                reply: reply)))
                    _ = await answer.first { _ in true }
                }
                continuation.yield(.generated(try! Output(GeneratedContent("Nobody was free."))))
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
