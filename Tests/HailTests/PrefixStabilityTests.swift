import AnyLanguageModel
import Foundation
import HailCore
import Testing

@testable import HailAgentRuntime

@Suite("Prompt prefix stability")
struct PrefixStabilityTests {
    private let agentID = AgentID(role: Role("scout"), contextID: .main)

    private func prompt(_ content: String) -> Transcript.Entry {
        .prompt(
            .init(
                id: "prompt-\(content)",
                segments: [.text(.init(id: "text-\(content)", content: content))]
            )
        )
    }

    private func response(_ content: String) -> Transcript.Entry {
        .response(
            .init(
                id: "response-\(content)",
                assetIDs: [],
                segments: [.text(.init(id: "text-\(content)", content: content))]
            )
        )
    }

    @Test("request-time context sits between history and the open turn")
    func contextPrecedesOpenTurn() {
        let request = PreparedRequest(prefix: [prompt("sys")], history: [response("previous")], openTurn: [prompt("current")])
            .adding(context: [prompt("reference")], tools: [])

        #expect(request.entries == [prompt("sys"), response("previous"), prompt("reference"), prompt("current")])
    }

    @Test("a fold changes the prefix and history, and the open turn's input stays last")
    func foldKeepsOpenTurnLast() throws {
        let earlier = TurnID()
        var history = AgentHistory()
        for (id, text) in [(earlier, "earlier"), (TurnID(), "current")] {
            history = try history.applying(
                .received(.init(from: .user(id: "u"), content: GeneratedContent(text), at: Date(timeIntervalSince1970: 1)), turn: id))
            if id == earlier {
                history = try history.applying(.replied(.init(content: GeneratedContent("done"), at: Date(timeIntervalSince1970: 1))))
            }
        }
        let folded = try history.applying(
            .compacted(.init(context: GeneratedContent("summary"), report: GeneratedContent("summary")), through: .after(earlier), kept: .none))

        let before = assembleStandardPrompt(try context(history))
        let after = assembleStandardPrompt(try context(folded))

        #expect(before.openTurn.count == after.openTurn.count)
        #expect(after.history.isEmpty)
        guard case .prompt(let last)? = after.entries.last, case .text(let text)? = last.segments.first else {
            Issue.record("Expected the request to end with the open turn's input")
            return
        }
        #expect(text.content == "current")
    }

    private func context(_ history: AgentHistory) throws -> PromptContext {
        PromptContext(
            agentID: agentID,
            definition: AgentDefinition(role: agentID.role, behavior: .init(systemPrompt: "sys")),
            modelConfiguration: ModelConfiguration(model: try AgentModel("test/fake")),
            history: history,
            contextManifest: ContextManifest(items: [])
        )
    }
}
