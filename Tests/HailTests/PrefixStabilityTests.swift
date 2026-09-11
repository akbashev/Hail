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

    @Test("the turn prompt keeps request-local context before the current entry")
    func turnContextPrecedesCurrentEntry() {
        let history = [response("previous"), prompt("current")]
        let reference = prompt("reference")
        let turn = TurnPrompt(
            input: "current",
            reference: [reference],
            currentEntry: history[1],
            currentSourceIndex: 1,
            currentIndex: 1,
            in: history
        )

        #expect(turn.entries == [history[0], reference, history[1]])
    }

    @Test("tool calls and outputs append after the current entry")
    func toolEntriesStayAtTurnTail() {
        let current = prompt("check this")
        let call = Transcript.ToolCall(
            id: "call-1",
            toolName: "check",
            arguments: GeneratedContent(properties: [:])
        )
        let turn = TurnPrompt(
            input: "check this",
            reference: [],
            currentEntry: current,
            currentSourceIndex: 0,
            currentIndex: 0,
            in: [current]
        )
        let calls = Transcript.ToolCalls(id: "calls-1", [call])
        let withCall = turn.appending(.toolCalls(calls))
        let output = Transcript.ToolOutput(
            id: "output-1",
            toolName: "check",
            segments: [.text(.init(id: "output-text-1", content: "done"))]
        )
        let withOutput = withCall.appending(
            .toolOutput(output)
        )

        #expect(withOutput.entries == [current, .toolCalls(calls), .toolOutput(output)])
    }

    @Test("rebasing replaces durable history without losing the live tail")
    func rebasingPreservesCurrentPrompt() {
        let old = response("old")
        let current = prompt("current")
        let reference = prompt("reference")
        let turn = TurnPrompt(
            input: "current",
            reference: [reference],
            currentEntry: current,
            currentSourceIndex: 1,
            currentIndex: 1,
            in: [old, current]
        )
        let toolCall = Transcript.Entry.toolCalls(
            .init([
                .init(
                    id: "call-1",
                    toolName: "check",
                    arguments: GeneratedContent(properties: [:])
                )
            ])
        )
        let live = turn.appending(toolCall)
        let summary = response("summary")
        let request = PreparedRequest(
            prefix: [summary],
            conversation: [
                .init(sourceIndex: 1, entry: current)
            ]
        )

        let rebased = live.rebased(on: request)

        #expect(rebased.entries == [summary, reference, current, toolCall])
    }

    @Test("assembled requests expose native transcript entries")
    func assembledRequestsExposeNativeEntries() throws {
        let context = PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModel("test/fake")
                )
            ),
            conversationThread: [
                .text(sender: "user", content: "hello", timestamp: Date(timeIntervalSince1970: 1))
            ],
            contextManifest: ContextManifest(items: [])
        )

        let request = assembleStandardPrompt(context)

        #expect(request.conversation.count == 1)
        guard case .prompt(let current)? = request.entries.last else {
            Issue.record("Expected the assembled request to end with a prompt")
            return
        }
        guard case .text(let text)? = current.segments.first else {
            Issue.record("Expected the current prompt to contain text")
            return
        }
        #expect(text.content == "hello")
    }
}
