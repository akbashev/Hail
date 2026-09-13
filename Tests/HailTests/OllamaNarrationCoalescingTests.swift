import AnyLanguageModel
import Foundation
import Hail
import Testing

@testable import HailModelRuntime

/// Ollama streams one content fragment per chunk (often a single token).
/// Narration must coalesce those fragments into one segment: per-fragment
/// segments would render as word-per-line when the transcript is rebuilt for
/// a later request, and models reliably mimic that formatting.
@Suite("Ollama narration coalescing")
struct OllamaNarrationCoalescingTests {
    private func endpoint(respondingWith ndjson: String) -> OllamaEndpoint {
        OllamaEndpoint(
            model: "test/model",
            baseURL: URL(string: "http://127.0.0.1:1")!,
            temperature: 0,
            transport: { _ in
                OllamaHTTPResponse(
                    statusCode: 200,
                    lines: AsyncThrowingStream { continuation in
                        for line in ndjson.split(separator: "\n") {
                            continuation.yield(String(line))
                        }
                        continuation.finish()
                    }
                )
            }
        )
    }

    @Test("per-fragment narration coalesces into a single text segment")
    func narrationCoalesces() async throws {
        let ndjson = #"""
            {"message":{"content":"You're"},"done":false}
            {"message":{"content":" absolutely"},"done":false}
            {"message":{"tool_calls":[{"id":"call_1","function":{"name":"now","arguments":{"time_zone":"Europe/Berlin"}}}]},"done":false}
            {"done":true,"done_reason":"stop"}
            """#
        var round: ModelToolRound? = nil
        for await event in endpoint(respondingWith: ndjson).stream(
            request: ModelRequest(input: "check", entries: []),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            if case .toolsRequested(let value) = event {
                round = value
            }
        }
        let narration = try #require(round?.narration)
        let segments = narration.segments
        #expect(segments.count == 1)
        guard case .text(let text) = try #require(segments.first) else {
            Issue.record("expected a text segment")
            return
        }
        #expect(text.content == "You're absolutely")
    }
}
