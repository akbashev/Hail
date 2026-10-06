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
        case .toolCalls, .toolOutput, .reasoning: return ""
        }
        return segments.map { segment in
            switch segment {
            case .text(let value): return value.content
            case .structure(let value): return value.content.jsonString
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }

    @Test("structured responses remain visible to subsequent model turns")
    func structuredResponseIsPreserved() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("coder"), contextID: .chat),
            definition: try definition(role: "coder", systemPrompt: "Code."),
            modelConfiguration: testModelConfiguration,
            conversationThread: [
                .response(
                    sender: "coder-chat",
                    content: GeneratedContent(properties: ["answer": 42]),
                    timestamp: Date()
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let entry = try #require(assembleStandardPrompt(context).conversation.first?.entry)

        guard case .response(let response) = entry,
            case .structure(let structure) = response.segments.first
        else {
            Issue.record("Expected a structured transcript response")
            return
        }
        #expect(structure.content.jsonString == #"{"answer":42}"#)
    }

    @Test("historical responses from another sender become prompts")
    func historicalResponseKeepsConversationRole() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: try definition(),
            modelConfiguration: testModelConfiguration,
            conversationThread: [
                .response(
                    sender: "participant:telegram:42",
                    content: GeneratedContent("hello"),
                    timestamp: Date()
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let entry = try #require(assembleStandardPrompt(context).conversation.first?.entry)
        guard case .prompt = entry else {
            Issue.record("An external response must be a model prompt")
            return
        }
    }

    @Test("historical text from the agent remains a response")
    func agentTextKeepsResponseRole() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: try definition(),
            modelConfiguration: testModelConfiguration,
            conversationThread: [
                .text(
                    sender: "conversation-chat",
                    content: "hello",
                    timestamp: Date(timeIntervalSince1970: 1)
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let entry = try #require(assembleStandardPrompt(context).conversation.first?.entry)
        guard case .response = entry else {
            Issue.record("Agent-authored text must be a transcript response")
            return
        }
    }

    @Test("tool results retain their originating tool name")
    func toolResultRetainsName() throws {
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: try definition(),
            modelConfiguration: testModelConfiguration,
            conversationThread: [
                .toolResult(
                    id: "call-1",
                    name: "getWeather",
                    output: .text("sunny"),
                    timestamp: Date()
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let entry = try #require(assembleStandardPrompt(context).conversation.first?.entry)
        guard case .toolOutput(let output) = entry else {
            Issue.record("Expected a transcript tool output")
            return
        }
        #expect(output.toolName == "getWeather")
    }

    @Test("assistant tool rounds keep reasoning out of visible transcript")
    func assistantToolRoundKeepsReasoningOutOfTranscript() throws {
        let call = ToolCall(
            id: "call-1",
            name: "getWeather",
            arguments: GeneratedContent(properties: [:])
        )
        let context = PromptContext(
            agentID: AgentID(role: Role("conversation"), contextID: .chat),
            definition: try definition(),
            modelConfiguration: testModelConfiguration,
            conversationThread: [
                .assistantToolCall(
                    round: ModelToolRound(
                        narration: Transcript.Response(
                            assetIDs: [],
                            segments: [.text(.init(content: "I will check."))]
                        ),
                        reasoning: [.text(.init(content: "The user needs current data."))],
                        calls: [call]
                    ),
                    timestamp: Date()
                )
            ],
            contextManifest: ContextManifest(items: [])
        )

        let entries = assembleStandardPrompt(context).conversation.map(\.entry)
        guard
            case .response(let response) = entries.first,
            case .text(let narration) = response.segments.first,
            case .toolCalls = entries.dropFirst().first
        else {
            Issue.record("Expected narration and tool-call transcript entries")
            return
        }

        #expect(narration.content == "I will check.")
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
            conversationThread: [],
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
            conversationThread: [],
            contextManifest: ContextManifest(items: []),
            instructions: PromptAssemblyInstructions(
                task: "Follow the host application's acceptance criteria."
            )
        )

        let prefix = assembleStandardPrompt(context).prefix

        #expect(text(in: prefix.last!) == "Follow the host application's acceptance criteria.")
    }
}
