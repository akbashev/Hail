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
    @Test("rebuilt transcript IDs do not change content hashes")
    func regeneratedIDsDoNotChangeContent() {
        func entries() -> [Transcript.Entry] {
            [
                .instructions(.init(segments: [.text(.init(content: "system"))], toolDefinitions: [])),
                .prompt(.init(segments: [.text(.init(content: "hello"))])),
                .response(.init(assetIDs: [], segments: [.text(.init(content: "reply"))])),
                .toolCalls(
                    .init([
                        .init(id: "call-1", toolName: "tool", arguments: GeneratedContent(properties: [:]))
                    ])),
                .toolOutput(
                    .init(id: "call-1", toolName: "tool", segments: [.text(.init(content: "result"))])),
            ]
        }
        #expect(
            RequestContentHash.chain(tools: [], messages: entries())
                == RequestContentHash.chain(tools: [], messages: entries()))
    }

    @Test("tool invocation identity remains part of the hash")
    func toolCallIdentityMatters() {
        func call(_ id: String) -> Transcript.Entry {
            .toolCalls(
                .init([.init(id: id, toolName: "tool", arguments: GeneratedContent(properties: [:]))]))
        }
        #expect(
            RequestContentHash.chain(tools: [], messages: [call("one")])
                != RequestContentHash.chain(tools: [], messages: [call("two")]))
    }

}
