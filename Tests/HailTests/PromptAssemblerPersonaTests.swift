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
                model: try AgentModel("test/model")
            ),
        )
        let payload = try JSONEncoder().encode(Response(answer: 42))
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: definition,
            conversationThread: [
                .response(sender: "assistant", payload: payload, timestamp: Date())
            ],
            contextManifest: ContextManifest(items: [])
        )

        let request = assembleStandardPrompt(context)

        #expect(request.conversation.map(\.message.content) == [#"{"answer":42}"#])
    }

    @Test("structured responses with extra fields are not mistaken for legacy chat wrappers")
    func structuredResponseWithExtraFieldsIsPreserved() throws {
        let definition = AgentDefinition(
            role: Role("conversation"),
            behavior: .init(
                systemPrompt: "Chat.",
                model: try AgentModel("test/model")
            ),
        )
        let payload = Data(#"{"content":"hello","citations":["source-1"]}"#.utf8)
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: definition,
            conversationThread: [
                .response(sender: "conversation", payload: payload, timestamp: Date())
            ],
            contextManifest: ContextManifest(items: [])
        )

        let message = try #require(assembleStandardPrompt(context).conversation.first?.message)

        #expect(message.content == String(decoding: payload, as: UTF8.self))
    }

    @Test("historical response keeps its external sender identity")
    func historicalResponsePreservesSender() throws {
        let definition = AgentDefinition(
            role: Role("conversation"),
            behavior: .init(
                systemPrompt: "Chat.",
                model: try AgentModel("test/model")
            ),
        )
        let payload = Data(#""hello""#.utf8)
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: definition,
            conversationThread: [
                .response(sender: "participant:telegram:42", payload: payload, timestamp: Date())
            ],
            contextManifest: ContextManifest(items: [])
        )

        let message = try #require(assembleStandardPrompt(context).conversation.first?.message)

        #expect(message.role == .user)
        #expect(message.name == "participant:telegram:42")
        #expect(message.content == "hello")
    }

    @Test("historical text keeps its sender identity")
    func historicalTextPreservesSender() throws {
        let definition = AgentDefinition(
            role: Role("conversation"),
            behavior: .init(
                systemPrompt: "Chat.",
                model: try AgentModel("test/model")
            ),
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: definition,
            conversationThread: [
                .text(
                    sender: "participant:telegram:42",
                    content: "hello",
                    timestamp: Date(timeIntervalSince1970: 1)
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let message = assembleStandardPrompt(context).conversation[0].message

        #expect(message.role == .user)
        #expect(message.content == "hello")
        #expect(message.name == "participant:telegram:42")
    }

    @Test("legacy chat response wrappers are rendered as text")
    func legacyChatResponseIsUnwrapped() throws {
        let definition = AgentDefinition(
            role: Role("conversation"),
            behavior: .init(
                systemPrompt: "Chat.",
                model: try AgentModel("test/model")
            ),
        )
        let legacyResponse = ChatResponse(content: "{\"content\":\"hello\"}")
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: definition,
            conversationThread: [
                .response(
                    sender: "conversation",
                    payload: try JSONEncoder().encode(legacyResponse),
                    timestamp: Date(timeIntervalSince1970: 1)
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let message = assembleStandardPrompt(context).conversation[0].message

        #expect(message.content == "hello")
    }

    @Test("adds durable persona identity after the operational system prompt")
    func addsPersonaIdentity() throws {
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(
                systemPrompt: "Implement the assigned change.",
                model: try AgentModel("test/model")
            ),
            persona: AgentPersona(
                displayName: "Ripley",
                instructions: "You are calm, direct, and deeply curious about alien life."
            )
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: definition,
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
                model: try AgentModel("test/model")
            ),
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: AgentContextID("build")),
            definition: definition,
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
