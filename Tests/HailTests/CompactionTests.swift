import AnyLanguageModel
import Foundation
import Hail
import HailAgentRuntime
import Testing

@Suite("Typed compaction")
struct CompactionTests {
    private let agentID = AgentID(role: Role("coder"), contextID: AgentContextID("conversation"))

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
