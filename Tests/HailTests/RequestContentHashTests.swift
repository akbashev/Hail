import AnyLanguageModel
import Hail
import Testing

@Suite("Request content hashing")
struct RequestContentHashTests {
    private func message(_ content: String) -> Transcript.Entry {
        .prompt(
            .init(
                id: "prompt-\(content)",
                segments: [.text(.init(id: "text-\(content)", content: content))]
            )
        )
    }

    @Test("identical prefixes produce identical digests")
    func identicalPrefixesMatch() {
        let round1 = RequestContentHash.chain(
            tools: [],
            messages: [message("a"), message("b")]
        )
        let round2 = RequestContentHash.chain(
            tools: [],
            messages: [message("a"), message("b"), message("c")]
        )

        #expect(round1 == Array(round2.prefix(round1.count)))
    }

    @Test("a changed element diverges the chain from that index on")
    func changeDivergesFromIndex() {
        let round1 = RequestContentHash.chain(
            tools: [],
            messages: [message("a"), message("b"), message("c")]
        )
        let round2 = RequestContentHash.chain(
            tools: [],
            messages: [message("a"), message("B"), message("c")]
        )

        #expect(round1[0] == round2[0])
        #expect(round1[1] == round2[1])
        #expect(round1[2] != round2[2])
        #expect(round1[3] != round2[3])
    }

    @Test("tool schemas are the first chain element")
    func toolsAreFirstElement() {
        let withTools = RequestContentHash.chain(
            tools: [
                TestToolDefinition.empty(name: "now", description: "clock")
            ],
            messages: [message("a")]
        )
        let withoutTools = RequestContentHash.chain(tools: [], messages: [message("a")])

        #expect(withTools[0] != withoutTools[0])
        #expect(withTools[1] != withoutTools[1])
    }
}
