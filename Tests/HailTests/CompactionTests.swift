import AnyLanguageModel
import Foundation
import Hail
import HailAgentRuntime
import Testing

@Suite("Typed compaction")
struct CompactionTests {
    private let agentID = AgentID(role: Role("coder"), contextID: AgentContextID("conversation"))

    private func message(_ content: String, at offset: TimeInterval) -> ChatMessage {
        .text(
            sender: "user",
            content: content,
            timestamp: Date(timeIntervalSince1970: offset)
        )
    }

    @Test("compaction content is stored as generated content, not rendered text")
    func stateStoresTypedCompactionContent() {
        var state = AgentState(
            agentID: agentID,
            conversationThread: [
                message("one", at: 1),
                message("two", at: 2),
                message("three", at: 3),
            ]
        )

        let content = GeneratedContent(properties: ["facts": ["one", "two"]])
        state.apply(.conversationCompacted(archivedCount: 2, content: content))

        #expect(state.contextSummary == content)
        #expect(state.conversationThread == [message("three", at: 3)])
    }

    @Test("generic compaction results retain their concrete generated output")
    func resultRetainsOutputType() {
        let result = CompactionResult(output: GeneratedContent("summary"), archivedCount: 4)

        #expect(result.output == GeneratedContent("summary"))
        #expect(result.archivedCount == 4)
    }

    @Test("summary requests carry transcript entries and an explicit output budget")
    func summaryRequestIsTypedAtTheBoundary() {
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "old exchange"))]))
        ]
        let request = CompactionSummaryRequest(entries: entries, maxOutputTokens: 2_048)

        #expect(request.entries == entries)
        #expect(request.maxOutputTokens == 2_048)
    }
}
