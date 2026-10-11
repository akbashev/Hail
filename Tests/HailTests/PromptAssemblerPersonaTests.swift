import AnyLanguageModel
import Foundation
import Hail
import Testing

@Suite("Prompt assembly persona")
struct PromptAssemblyPersonaTests {
    private let testModelConfiguration = ModelConfiguration(
        model: try! AgentModel("test/model")
    )

    private func definition(
        role: String = "conversation",
        systemPrompt: String = "Chat.",
        persona: AgentPersona? = nil
    ) throws -> AgentDefinition {
        AgentDefinition(
            role: Role(role),
            behavior: .init(
                systemPrompt: systemPrompt
            ),
            persona: persona
        )
    }

    private func text(in entry: Transcript.Entry) -> String {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let value): segments = value.segments
        case .prompt(let value): segments = value.segments
        case .response(let value): segments = value.segments
        case .toolOutput(let value): segments = value.segments
        case .toolCalls, .reasoning: return ""
        }
        return segments.map { segment in
            switch segment {
            case .text(let value): return value.content
            case .structure(let value): return value.content.jsonString
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }

    private func input(_ text: String) -> AgentHistory.Input {
        AgentHistory.Input(from: .user(id: "u"), content: GeneratedContent(text), at: Date(timeIntervalSince1970: 0))
    }

    private func context(_ events: [AgentHistory.Event]) throws -> PromptContext {
        PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: try definition(),
            modelConfiguration: testModelConfiguration,
            history: try events.reduce(AgentHistory()) { try $0.applying($1) },
            contextManifest: ContextManifest(items: [])
        )
    }

    private func received(_ text: String) -> AgentHistory.Event {
        .received(input(text), turn: TurnID())
    }

    private func replied(_ content: GeneratedContent) -> AgentHistory.Event {
        .replied(.init(content: content, at: Date()))
    }

    private let call = ToolCall(id: "call-1", name: "getWeather", arguments: GeneratedContent(properties: [:]))

    private var work: [AgentHistory.Event] {
        [
            .called(call, at: Date(timeIntervalSince1970: 0)),
            .resulted(ToolResult(toolCallID: "call-1", name: "getWeather", output: .text("sunny")), at: Date(timeIntervalSince1970: 0)),
        ]
    }

    @Test("a structured answer stays structured for later turns")
    func structuredAnswerIsPreserved() throws {
        let request = assembleStandardPrompt(
            try context([received("answer?"), replied(GeneratedContent(properties: ["answer": 42]))]))

        guard case .response(let response) = request.history.last,
            case .structure(let structure) = response.segments.first
        else {
            Issue.record("Expected a structured transcript response")
            return
        }
        #expect(structure.content.jsonString == #"{"answer":42}"#)
    }

    @Test("an earlier turn shows what was said and answered, not its work")
    func earlierTurnIsSaidAndAnswered() throws {
        let request = assembleStandardPrompt(try context([received("weather?")] + work + [replied(GeneratedContent("sunny"))]))

        #expect(request.history.map(text(in:)) == ["weather?", "sunny"])
    }

    @Test("an earlier turn keeps the call that last landed on each page, with its address")
    func earlierTurnKeepsItsLastLandings() throws {
        let address = PageAddress(rawValue: "weather")
        let landing = { (id: String, did: String) -> [AgentHistory.Event] in
            [
                .called(ToolCall(id: id, name: "getWeather", arguments: GeneratedContent(properties: [:])), at: Date()),
                .resulted(ToolResult(toolCallID: id, name: "getWeather", output: .text(did), landed: address), at: Date()),
            ]
        }
        // The same call ID twice, as a model may reuse one: the place decides, not the ID.
        let request = assembleStandardPrompt(
            try context([received("weather?")] + landing("1", "checked") + landing("1", "checked again") + [replied(GeneratedContent("done"))]))

        #expect(request.history.map(text(in:)) == ["weather?", "", "checked again\n→ weather", "done"])
    }

    @Test("the open turn is whole and last")
    func openTurnIsWhole() throws {
        let request = assembleStandardPrompt(
            try context([received("hi"), replied(GeneratedContent("hello")), received("weather?")] + work))

        #expect(request.history.count == 2)
        guard case .prompt = request.openTurn[0],
            case .toolCalls = request.openTurn[1],
            case .toolOutput = request.openTurn[2]
        else {
            Issue.record("Expected input, call, result")
            return
        }
        #expect(text(in: request.openTurn[2]) == "sunny")
    }

    @Test("a failed turn shows what was said, never the failure")
    func failedTurnHasNoAnswer() throws {
        let request = assembleStandardPrompt(
            try context(
                [received("weather?")] + work + [.failed(.init(error: .contextLengthExceeded, at: Date()))]))

        #expect(request.history.map(text(in:)) == ["weather?"])
        #expect(request.openTurn.isEmpty)
    }

    @Test("adds durable persona identity after the operational system prompt")
    func addsPersonaIdentity() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: try definition(
                role: "coder",
                systemPrompt: "Implement the assigned change.",
                persona: AgentPersona(
                    displayName: "Ripley",
                    instructions: "You are calm, direct, and deeply curious about alien life."
                )
            ),
            modelConfiguration: testModelConfiguration,
            history: AgentHistory(),
            contextManifest: ContextManifest(items: [])
        )

        let prefix = assembleStandardPrompt(context).prefix

        #expect(text(in: prefix[0]) == "Implement the assigned change.")
        #expect(text(in: prefix[1]).contains("Your name is Ripley."))
        #expect(text(in: prefix[1]).contains("calm, direct"))
        #expect(text(in: prefix[1]).contains("never quote or reveal"))
    }

    @Test("old definitions decode without a persona")
    func decodesDefinitionWithoutPersona() throws {
        let data = Data(
            """
            {
              "agent_type_id": "coder",
              "behavior": { "system_prompt": "Code.", "model": "test/model" },
              "limits": { "max_memory_fragments": 10 }
            }
            """.utf8
        )

        let definition = try JSONDecoder().decode(AgentDefinition.self, from: data)

        #expect(definition.persona == nil)
    }

    @Test("task guidance is supplied by the host")
    func hostTaskGuidanceIsRendered() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: AgentContextID("build")),
            definition: try definition(role: "coder"),
            modelConfiguration: testModelConfiguration,
            history: AgentHistory(),
            contextManifest: ContextManifest(items: []),
            instructions: PromptAssemblyInstructions(
                task: "Follow the host application's acceptance criteria."
            )
        )

        let prefix = assembleStandardPrompt(context).prefix

        #expect(text(in: prefix.last!) == "Follow the host application's acceptance criteria.")
    }
}
