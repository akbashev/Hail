import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Model input artifacts")
struct ModelInputTests {
    @Test("text-like artifacts remain usable by text-only endpoints")
    func textLikeArtifactProjectsToText() throws {
        var input = ModelInput(messages: [LLMMessage(role: .user, content: "inspect")])
        input.appendToolOutput(
            callID: "call-1",
            name: "fetch",
            output: .data(ToolData(body: Data(#"{"ok":true}"#.utf8), contentType: "application/json; charset=utf-8"))
        )

        #expect(!input.containsUnsupportedData)
        let messages = try input.textMessages(for: "text-only")
        #expect(messages.last?.content == #"{"ok":true}"#)
    }

    @Test("unsupported artifacts fail explicitly instead of becoming metadata")
    func unsupportedArtifactFails() {
        var input = ModelInput(messages: [])
        input.appendToolOutput(
            callID: "call-1",
            name: "fetch",
            output: .data(ToolData(body: Data([0, 1, 2]), contentType: "audio/mpeg"))
        )

        #expect(input.containsUnsupportedData)
        #expect(throws: ModelEndpointError.invalidRequest("Model endpoint text-only cannot consume the data returned by this tool.")) {
            try input.textMessages(for: "text-only")
        }
    }

}
