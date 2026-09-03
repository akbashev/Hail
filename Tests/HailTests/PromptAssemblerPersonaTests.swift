import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Prompt assembly persona")
struct PromptAssemblyPersonaTests {
    @Test("structured responses remain visible to subsequent model turns")
    func structuredResponseIsPreserved() throws {
        struct Response: Codable {
            let answer: Int
        }
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(
                systemPrompt: "Code.",
                model: try AgentModelReference("test/model")
            ),
            limits: .init()
        )
        let payload = try JSONEncoder().encode(Response(answer: 42))
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: definition,
            workingMemory: [],
            conversationThread: [
                .response(sender: "assistant", payload: payload, timestamp: Date())
            ],
            contextManifest: ContextManifest(items: [])
        )

        let request = assembleStandardPrompt(context)

        #expect(request.conversation.map(\.message.content) == [#"{"answer":42}"#])
    }

    @Test("adds durable persona identity after the operational system prompt")
    func addsPersonaIdentity() throws {
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(
                systemPrompt: "Implement the assigned change.",
                model: try AgentModelReference("test/model")
            ),
            limits: .init(),
            persona: AgentPersona(
                displayName: "Ripley",
                instructions: "You are calm, direct, and deeply curious about alien life."
            )
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: definition,
            workingMemory: [],
            conversationThread: [],
            contextManifest: ContextManifest(items: [])
        )

        let messages = assembleStandardPrompt(context).messages

        #expect(messages[0].content == "Implement the assigned change.")
        #expect(messages[1].role == .system)
        #expect(messages[1].content.contains("Your name is Ripley."))
        #expect(messages[1].content.contains("calm, direct"))
        #expect(messages[1].content.contains("never quote or reveal"))
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
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(
                systemPrompt: "Code.",
                model: try AgentModelReference("test/model")
            ),
            limits: .init()
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: AgentContextID("build")),
            definition: definition,
            workingMemory: [],
            conversationThread: [],
            contextManifest: ContextManifest(items: []),
            instructions: PromptAssemblyInstructions(
                task: "Follow the host application's acceptance criteria."
            )
        )

        let messages = assembleStandardPrompt(context).messages

        #expect(messages.last?.content == "Follow the host application's acceptance criteria.")
    }
}
