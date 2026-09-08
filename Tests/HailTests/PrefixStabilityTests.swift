import HailCore
import Testing

@testable import HailAgentRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Prefix caching across turns only works when the history rebuilt from the
/// journal renders exactly like the messages the live turn appended in
/// memory. These tests pin that invariant: a journaled tool round must come
/// back as the same single assistant message, and per-turn context must stay
/// ephemeral.
@Suite("Prompt prefix stability")
struct PrefixStabilityTests {
    private let agentID = AgentID(role: Role("scout"), contextID: .main)

    private func assemble(_ state: AgentState) throws -> [LLMMessage] {
        assembleStandardPrompt(
            PromptContext(
                agentID: agentID,
                definition: AgentDefinition(
                    role: agentID.role,
                    behavior: .init(
                        systemPrompt: "sys",
                        model: try AgentModelReference("test/fake")
                    ),
                    limits: .init()
                ),
                workingMemory: [],
                contextSummary: state.contextSummary,
                conversationThread: state.conversationThread,
                contextManifest: ContextManifest(items: [])
            )
        ).messages
    }

    private func fingerprint(_ message: LLMMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    @Test("a journaled tool round rebuilds into the exact messages the live turn sent")
    func rebuiltToolRoundMatchesLiveRendering() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let userMessage = ChatMessage.text(
            sender: "user",
            content: "what time is it?",
            timestamp: at
        )
        let call = ToolCall(id: "call-1", name: "now", arguments: .empty)
        let thinking = "The user wants the current time."
        let narration = "Let me check."
        let toolOutput = "2023-11-14T22:13:20Z"

        // Turn 1, live: request-local context is placed immediately before
        // the journaled user message; the tool round is then appended in
        // memory as one assistant message plus the tool result.
        var state = AgentState(agentID: agentID)
        state.apply(.messageReceived(userMessage), maxMemoryFragments: 10)
        let turnOnePrefix = try assemble(state)

        let turnContext = LLMMessage(
            role: .user,
            content:
                "Context for this turn (not a separate user request):\nIncoming message timestamp: 2023-11-14T22:13:00Z"
        )
        let assistantRound = LLMMessage(
            role: .assistant,
            content: narration,
            thinking: thinking,
            toolCalls: [LLMToolCall(call)]
        )

        let livePrompt = TurnPrompt(
            reference: [turnContext],
            currentMessage: turnOnePrefix.last,
            in: turnOnePrefix
        )
        var liveInput = livePrompt.modelInput
        liveInput.append(assistantRound)
        liveInput.appendToolOutput(callID: call.id, name: call.name, output: .text(toolOutput))
        let liveRoundTwo = liveInput.messages

        // Turn 2: the same turn rebuilt from its journaled events.
        state.apply(
            .assistantToolRound(content: narration, thinking: thinking, calls: [call], at: at),
            maxMemoryFragments: 10
        )
        // ToolResult's memberwise init is module-internal; decoding exercises
        // the same journaled shape.
        let toolResult = try JSONDecoder().decode(
            ToolResult.self,
            from: Data(
                #"{"tool_call_id":"call-1","name":"now","output":"2023-11-14T22:13:20Z","is_error":false}"#
                    .utf8
            )
        )
        state.apply(
            .toolResult(toolResult, at: at),
            maxMemoryFragments: 10
        )
        let payload = try JSONEncoder().encode("It is 10:13 PM.")
        state.apply(
            .responseReceived(sender: agentID.rawValue, payload: payload, at: at),
            maxMemoryFragments: 10
        )
        let rebuilt = try assemble(state)

        // The stable prefix — everything before the current user message —
        // renders identically across the two turns.
        let stableCount = turnOnePrefix.count - 1
        try #expect(
            rebuilt.prefix(stableCount).map(fingerprint)
                == liveRoundTwo.prefix(stableCount).map(fingerprint)
        )

        // The current message is after the ephemeral context in the live
        // request. The durable rebuild omits that context and starts with the
        // current message, followed by the same tool round.
        try #expect(fingerprint(liveRoundTwo[stableCount]) == fingerprint(turnContext))
        try #expect(fingerprint(liveRoundTwo[stableCount + 1]) == fingerprint(turnOnePrefix.last!))
        try #expect(fingerprint(rebuilt[stableCount]) == fingerprint(turnOnePrefix.last!))
        #expect(rebuilt.count == stableCount + 4)
        try #expect(fingerprint(rebuilt[stableCount + 1]) == fingerprint(assistantRound))
        #expect(rebuilt[stableCount + 1].thinking == thinking)

        let rebuiltToolResult = rebuilt[stableCount + 2]
        #expect(rebuiltToolResult.role == .tool)
        #expect(rebuiltToolResult.content == toolOutput)
        #expect(rebuiltToolResult.toolCallID == call.id)
        try #expect(
            fingerprint(rebuiltToolResult) == fingerprint(liveRoundTwo[stableCount + 3])
        )

        let rebuiltResponse = rebuilt[stableCount + 3]
        #expect(rebuiltResponse.role == .assistant)
        #expect(rebuiltResponse.content == "It is 10:13 PM.")

        #expect(
            !rebuilt.contains { $0.content.contains("Context for this turn") }
        )
    }

    @Test("turn context precedes the current message and is not a system message")
    func turnContextPrecedesCurrentMessage() throws {
        // Mirrors how the reasoning loop places request-local context: it
        // remains outside the system prefix, but the actual user message is
        // the final user message so a context line cannot become the request.
        var state = AgentState(agentID: agentID)
        state.apply(
            .messageReceived(
                .text(sender: "user", content: "hi", timestamp: Date(timeIntervalSince1970: 1))
            ),
            maxMemoryFragments: 10
        )
        let durable = try assemble(state)

        let turnContext = LLMMessage(
            role: .user,
            content: "Context for this turn (not a separate user request):\nRelevant saved facts: likes tea"
        )
        let current = try #require(durable.last)
        let prompt = TurnPrompt(
            reference: [turnContext],
            currentMessage: current,
            in: durable
        )
        let request = prompt.messages

        #expect(turnContext.role == .user)
        #expect(request[request.count - 2] == turnContext)
        #expect(request.last == current)
        try #expect(
            request.dropLast(2).map(fingerprint)
                == durable.dropLast().map(fingerprint)
        )
    }

    @Test("tool messages stay after the current message")
    func toolMessagesStayAfterCurrentMessage() {
        let history = LLMMessage(role: .assistant, content: "previous")
        let current = LLMMessage(role: .user, content: "check this")
        let toolCall = LLMMessage(role: .assistant, content: "checking", toolCalls: [])
        let toolResult = LLMMessage(role: .tool, content: "done", toolCallID: "call-1")
        let context = LLMMessage(role: .user, content: "reference")

        let result = TurnPrompt(
            reference: [context],
            currentMessage: current,
            in: [history, current, toolCall, toolResult]
        ).messages

        #expect(result == [history, context, current, toolCall, toolResult])
    }

    @Test("compaction replaces history without rebuilding the live prompt")
    func rebasingPreservesCurrentPrompt() {
        let current = LLMMessage(role: .user, content: "check this")
        let context = LLMMessage(role: .user, content: "reference")
        let toolCall = LLMMessage(
            role: .assistant,
            content: "checking",
            toolCalls: [
                LLMToolCall(
                    id: "call-1",
                    type: "function",
                    function: .init(name: "check", arguments: "{}")
                )
            ]
        )
        let toolResult = LLMMessage(
            role: .tool,
            content: "done",
            toolCallID: "call-1"
        )
        let prompt = TurnPrompt(
            reference: [context],
            currentMessage: current,
            in: [LLMMessage(role: .assistant, content: "old"), current]
        )
        let live = prompt
            .appending(toolCall)
            .appending(toolResult)
        let rebased = live.rebased(
            on: [LLMMessage(role: .system, content: "summary"), current]
        )

        #expect(rebased.history.messages == [LLMMessage(role: .system, content: "summary")])
        #expect(rebased.current.messages == live.current.messages)
        #expect(
            rebased.messages == [
                LLMMessage(role: .system, content: "summary"),
                context,
                current,
                toolCall,
                toolResult,
            ]
        )
    }
}
