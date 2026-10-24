import AnyLanguageModel
import Distributed
import DistributedCluster
import Testing

@testable import HailAgentRuntime

/// An agent asked for no type answers in text; asked for one, in it. The text answer is a
/// function beside the distributed one, which it calls: from this node or another.
@Suite("Respond in text")
struct RespondInTextTests {
    @Test("asked for no type, an agent's respond is the text one; asked for one, the typed one")
    func theTypeChoosesTheFunction() {
        // Compiled, not run: which function each call is.
        let text: @Sendable (Agent) async throws -> String = { agent in try await agent.respond("Plan Saturday.") }
        let typed: @Sendable (Agent) async throws -> Plan = { agent in try await agent.respond("Plan Saturday.") }
        _ = (text, typed)
    }

    @Test("the text answer is reached on another node, and calls the distributed one once")
    func theTextAnswerWorksRemotely() async throws {
        let first = await ClusterSystem("first") { $0.bindPort = Int.random(in: 30_000...40_000) }
        let second = await ClusterSystem("second") { $0.bindPort = Int.random(in: 40_001...50_000) }
        defer {
            try? first.shutdown()
            try? second.shutdown()
        }
        second.cluster.join(endpoint: first.cluster.endpoint)
        try await first.cluster.waitFor(second.cluster.node, .up, within: .seconds(10))

        let answerer = Answerer(actorSystem: first)
        let remote = try Answerer.resolve(id: answerer.id, using: second)
        let answer: String = try await remote.respond("Plan Saturday.")
        #expect(answer == "Plan Saturday. answered as String")
        #expect(try await remote.calls == 1)
    }
}

@Generable
struct Plan: Codable, Sendable {
    let steps: [String]
}

extension Plan.PartiallyGenerated: Codable {}

/// An actor shaped as an agent is: a generic distributed `respond`, and a text one beside it.
distributed actor Answerer {
    typealias ActorSystem = ClusterSystem
    private var answered = 0

    distributed var calls: Int { answered }

    distributed func respond<Input: Codable & Sendable, Output: Codable & Sendable>(
        _ input: Input, authority lane: TurnAuthorityLane? = nil
    ) async throws -> Output {
        answered += 1
        guard let answer = "\(input) answered as \(Output.self)" as? Output else { throw AnswererError() }
        return answer
    }
}

extension Answerer {
    nonisolated func respond<Input: Codable & Sendable>(_ input: Input) async throws -> String {
        try await respond(input, authority: nil)
    }
}

struct AnswererError: Error, Codable {}
