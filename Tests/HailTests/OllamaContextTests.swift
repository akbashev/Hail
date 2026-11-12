import AnyLanguageModel
import HTTPTypes
import HailCore
import Synchronization
import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How much context an Ollama server gives a model: a server of your own is told; Ollama's cloud
/// keeps the model's own window, so it isn't; either way compaction knows the window.
@Suite("Ollama context")
struct OllamaContextTests {
    @Test(
        "a given window is sent as num_ctx, the model's own isn't, and both are the window",
        arguments: [(OllamaContext.given(16_384), 16_384 as Int?), (.own(1_048_576), nil)])
    func contextIsSentOnlyWhenGiven(_ context: OllamaContext, sent: Int?) async throws {
        let transport = RecordingTransport()
        let endpoint = AnyLanguageModelEndpoint.ollama(
            model: "qwen3", baseURL: URL(string: "http://127.0.0.1:11434")!, temperature: 0,
            context: context, transport: transport)

        for await _ in endpoint.stream(
            request: ModelRequest(input: "hi", entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))]),
            tools: [], authority: FullAuthority(), generating: String.self, purpose: .generation
        ) {}

        let body = try #require(transport.bodies.first)
        let request = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let numContext = (request["options"] as? [String: Any])?["num_ctx"] ?? request["num_ctx"]
        #expect(numContext as? Int == sent)
        #expect(endpoint.effectiveContextWindow == context.tokens)
    }
}

/// Keeps the bodies it's sent and refuses each request, so a request is made but never answered.
private final class RecordingTransport: HTTPTransport, Sendable {
    private let sent = Mutex<[Data]>([])

    var bodies: [Data] { sent.withLock { $0 } }

    @concurrent func send<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration?,
        responseHandler: @concurrent (HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        sent.withLock { $0.append(body ?? Data()) }
        throw CancellationError()
    }
}
