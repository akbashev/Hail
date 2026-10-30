import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A tool's data, as the model reads it: text it can read as its text, on every path to the model,
/// and anything else described.
@Suite("Tool output")
struct ToolOutputTests {
    @Test("text-like data is its text, as the transcript has it")
    func textLikeDataIsItsText() {
        let json = #"{"headers":{"X-Turgai-Check":"blue-kettle"}}"#
        let output = ToolOutput.data(
            ToolData(
                body: Data(json.utf8), contentType: "application/json; charset=utf-8",
                source: URL(string: "https://httpbin.org/headers")))
        #expect(output.textRepresentation == json)
    }

    @Test("other data is described: what it is, how much of it, and where it's from")
    func otherDataIsDescribed() {
        let output = ToolOutput.data(
            ToolData(body: Data([0, 1, 2]), contentType: "application/pdf", source: URL(string: "https://example.com/a.pdf")))
        #expect(output.textRepresentation == "Fetched 3 bytes from https://example.com/a.pdf with content type application/pdf.")
    }
}
