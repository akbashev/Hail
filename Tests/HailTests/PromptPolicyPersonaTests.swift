import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Prompt policy persona")
struct PromptPolicyPersonaTests {
    @Test("adds durable persona identity after the operational system prompt")
    func addsPersonaIdentity() {
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(systemPrompt: "Implement the assigned change.", model: "test"),
            limits: .init(),
            persona: AgentPersona(
                displayName: "Ripley",
                instructions: "You are calm, direct, and deeply curious about alien life."
            )
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: definition,
            projectRootPath: "/workspace",
            workingMemory: [],
            conversationThread: [],
            contextManifest: ContextManifest(items: [])
        )

        let messages = PromptPolicy.default.build(context)

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
              "behavior": { "system_prompt": "Code.", "model": "test" },
              "limits": { "max_memory_fragments": 10 }
            }
            """.utf8
        )

        let definition = try JSONDecoder().decode(AgentDefinition.self, from: data)

        #expect(definition.persona == nil)
    }
}
