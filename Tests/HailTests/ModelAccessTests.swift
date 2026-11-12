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

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// A provider's models are asked for with its address, key and transport, by the IDs a model is
/// made with, every page of them; a refused key throws the provider's answer.
@Suite("Available models")
struct AvailableModelsTests {
    @Test("OpenAI and servers compatible with it list their models, asked with a key or none")
    func openAI() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"object":"list","data":[{"id":"gpt-5","object":"model"},{"id":"gpt-5-mini"}]}"#),
            .init(#"{"data":[{"id":"qwen3"}]}"#),
        ])

        let models = try await ModelAccess.openAI(apiKey: "secret").availableModels(transport: transport)
        let local = try await ModelAccess.openAICompatible(
            baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: nil
        ).availableModels(transport: transport)

        #expect(models == ["gpt-5", "gpt-5-mini"])
        #expect(local == ["qwen3"])
        #expect(transport.requests.map(\.method) == [.get, .get])
        #expect(transport.requests.map(\.path) == ["/v1/models", "/v1/models"])
        #expect(transport.requests.map { $0.headerFields[.authorization] } == ["Bearer secret", nil])
    }

    @Test("Anthropic's models are every page of them, asked with its key and version")
    func anthropic() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"data":[{"id":"claude-a"},{"id":"claude-b"}],"has_more":true,"last_id":"claude-b"}"#),
            .init(#"{"data":[{"id":"claude-c"}],"has_more":false,"last_id":"claude-c"}"#),
        ])

        let models = try await ModelAccess.anthropic(apiKey: "secret").availableModels(transport: transport)

        #expect(models == ["claude-a", "claude-b", "claude-c"])
        #expect(
            transport.requests.map(\.path) == ["/v1/models?limit=1000", "/v1/models?limit=1000&after_id=claude-b"])
        let headers = try #require(transport.requests.first?.headerFields)
        #expect(headers[HTTPField.Name("x-api-key")!] == "secret")
        #expect(headers[HTTPField.Name("anthropic-version")!] == AnthropicLanguageModel.defaultAPIVersion)
    }

    @Test("a page whose cursor doesn't move is the last, so listing ends")
    func anthropicStopsWhenTheCursorStays() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#),
            .init(#"{"data":[],"has_more":true,"last_id":"claude-a"}"#),
        ])

        let models = try await ModelAccess.anthropic(apiKey: "secret").availableModels(transport: transport)

        #expect(models == ["claude-a"])
        #expect(transport.requests.count == 2)
    }

    @Test("Gemini's models are those that generate content, by their IDs, every page of them")
    func gemini() async throws {
        let transport = ScriptedTransport(replies: [
            .init(
                #"{"models":[{"name":"models/gemini-pro","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#
            ),
            .init(#"{"models":[{"name":"models/gemini-flash","supportedGenerationMethods":["generateContent"]}]}"#),
            .init("{}"),
        ])

        let models = try await ModelAccess.gemini(apiKey: "secret").availableModels(transport: transport)
        let none = try await ModelAccess.gemini(apiKey: "secret").availableModels(transport: transport)

        #expect(models == ["gemini-pro", "gemini-flash"])
        #expect(none.isEmpty)
        #expect(
            transport.requests.prefix(2).map(\.path) == [
                "/v1beta/models?pageSize=1000", "/v1beta/models?pageSize=1000&pageToken=next",
            ])
        #expect(transport.requests.first?.headerFields[HTTPField.Name("x-goog-api-key")!] == "secret")
    }

    @Test("an Ollama server lists the models it has, asked with its key or none")
    func ollama() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"models":[{"name":"qwen3:8b","model":"qwen3:8b"},{"name":"gpt-oss:120b"}]}"#),
            .init(#"{"models":[{"name":"gpt-oss:120b"}]}"#),
        ])

        let local = try await ModelAccess.ollama(baseURL: OllamaLanguageModel.defaultBaseURL, apiKey: nil)
            .availableModels(transport: transport)
        let cloud = try await ModelAccess.ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: "secret")
            .availableModels(transport: transport)

        #expect(local == ["qwen3:8b", "gpt-oss:120b"])
        #expect(cloud == ["gpt-oss:120b"])
        #expect(transport.requests.map(\.path) == ["/api/tags", "/api/tags"])
        #expect(transport.requests.map { $0.headerFields[.authorization] } == [nil, "Bearer secret"])
    }

    @Test(
        "a refused key throws that it's refused, with the provider's answer",
        arguments: [Provider.openAI, .anthropic, .gemini, .ollama])
    func aRefusedKeyThrowsTheAnswer(provider: Provider) async throws {
        let transport = ScriptedTransport(replies: [.init(provider.refusalAnswer, status: provider.refusal)])

        let unavailability = try await #require(throws: ModelUnavailability.self) {
            _ = try await provider.access.availableModels(transport: transport)
        }

        #expect(unavailability.kind == .keyRefused)
        let answer = try #require(unavailability.underlyingError as? HTTPTransportError)
        #expect(answer.response?.status == provider.refusal)
        #expect(answer.body == Data(provider.refusalAnswer.utf8))
    }

    @Test("a page that fails partway through fails the whole listing")
    func aFailingPageFailsTheListing() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#),
            .init("{}", status: .internalServerError),
        ])

        let unavailability = try await #require(throws: ModelUnavailability.self) {
            _ = try await ModelAccess.anthropic(apiKey: "secret").availableModels(transport: transport)
        }

        #expect(unavailability.kind == .providerError)
        #expect((unavailability.underlyingError as? HTTPTransportError)?.response?.status == .internalServerError)
    }

    @Test("an answer that isn't a list of models is a decoding error")
    func anUnreadableAnswerIsADecodingError() async throws {
        let transport = ScriptedTransport(replies: [.init(#"{"unexpected":true}"#)])

        let unavailability = try await #require(throws: ModelUnavailability.self) {
            _ = try await ModelAccess.openAI(apiKey: "secret").availableModels(transport: transport)
        }

        #expect(unavailability.kind == .providerError)
        #expect((unavailability.underlyingError as? HTTPTransportError)?.kind == .decodingError)
    }

    @Test("a listing cancelled while a page is asked for asks for no other")
    func cancellingStopsTheNextPage() async throws {
        let transport = WaitingForCancellation(
            answer: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#)
        let listing = Task { try await ModelAccess.anthropic(apiKey: "secret").availableModels(transport: transport) }
        while !transport.started { try await Task.sleep(for: .milliseconds(1)) }
        listing.cancel()

        await #expect(throws: CancellationError.self) { try await listing.value }
        #expect(transport.sent == 1)
    }

    enum Provider: CaseIterable, Sendable {
        case openAI, anthropic, gemini, ollama

        var access: ModelAccess {
            switch self {
            case .openAI: .openAI(apiKey: "wrong")
            case .anthropic: .anthropic(apiKey: "wrong")
            case .gemini: .gemini(apiKey: "wrong")
            case .ollama: .ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: "wrong")
            }
        }

        /// How it refuses a key: Gemini answers one that isn't valid with `400 Bad Request`.
        var refusal: HTTPResponse.Status {
            self == .gemini ? .badRequest : .unauthorized
        }

        /// What it answers with it: Gemini names the reason.
        var refusalAnswer: String {
            self == .gemini
                ? #"{"error":{"code":400,"details":[{"reason":"API_KEY_INVALID"}]}}"#
                : #"{"error":{"message":"invalid key"}}"#
        }
    }
}

/// Whether a model can be used now, asked where it runs: a provider says whether it takes the key
/// and has the model, and how many tokens it takes when it says.
@Suite("Checking availability")
struct CheckAvailabilityTests {
    @Test("an Ollama server answers for the key's account, then shows the model")
    func ollamaIsAvailable() async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"Name":"someone","Plan":"free"}"#),
            .init(
                #"{"modelfile":"FROM qwen3","model_info":{"general.architecture":"qwen3","qwen3.context_length":40960}}"#
            ),
        ])
        let access = ModelAccess.ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: "secret")

        #expect(
            try await access.checkAvailability(of: "qwen3", transport: transport).details
                == ModelDetails(contextSize: 40960))
        #expect(transport.requests.map(\.path) == ["/api/me", "/api/show"])
        #expect(transport.requests.map { $0.headerFields[.authorization] } == ["Bearer secret", "Bearer secret"])
        #expect(transport.bodies.last == Data(#"{"model":"qwen3"}"#.utf8))
    }

    @Test(
        "an Ollama server that refuses the key, or has no such model, says so",
        arguments: [
            (
                key: "secret", status: HTTPResponse.Status.unauthorized, show: false,
                kind: ModelUnavailability.Kind.keyRefused
            ),
            (key: nil, status: .unauthorized, show: true, kind: .keyNeeded),
            (key: nil, status: .notFound, show: true, kind: .modelNotFound),
            (key: "secret", status: .notFound, show: true, kind: .modelNotFound),
            (key: "secret", status: .notFound, show: false, kind: .providerError),
            (key: "secret", status: .internalServerError, show: true, kind: .providerError),
        ] as [(key: String?, status: HTTPResponse.Status, show: Bool, kind: ModelUnavailability.Kind)])
    func ollamaIsUnavailable(
        _ outcome: (key: String?, status: HTTPResponse.Status, show: Bool, kind: ModelUnavailability.Kind)
    ) async throws {
        // With a key, its account is asked for first, and `api/show` after the key is taken;
        // without one, only `api/show` is asked.
        let accountAnswered = outcome.show && outcome.key != nil
        let transport = ScriptedTransport(
            replies: (accountAnswered ? [.init(#"{"Name":"someone"}"#)] : [])
                + [.init(#"{"error":"no"}"#, status: outcome.status)])
        let access = ModelAccess.ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: outcome.key)

        let unavailability = try #require(
            try await access.checkAvailability(of: "qwen3", transport: transport).unavailability)

        #expect(transport.requests.first?.path == (outcome.key == nil ? "/api/show" : "/api/me"))
        #expect(unavailability.kind == outcome.kind)
        #expect((unavailability.underlyingError as? HTTPTransportError)?.response?.status == outcome.status)
    }

    @Test("an Ollama server of your own is asked for no account, and may not say a context length")
    func ollamaWithoutAKey() async throws {
        let transport = ScriptedTransport(replies: [.init(#"{"modelfile":"FROM qwen3"}"#)])
        let access = ModelAccess.ollama(baseURL: OllamaLanguageModel.defaultBaseURL, apiKey: nil)

        #expect(try await access.checkAvailability(of: "qwen3", transport: transport).details == ModelDetails())
        #expect(transport.requests.map(\.path) == ["/api/show"])
        #expect(transport.requests.map { $0.headerFields[.authorization] } == [nil])
    }

    @Test("OpenAI and servers compatible with it are available when they list the model")
    func openAI() async throws {
        let listing = #"{"data":[{"id":"gpt-5"}]}"#
        let transport = ScriptedTransport(replies: [.init(listing), .init(listing)])
        let local = ModelAccess.openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: "")

        #expect(
            try await ModelAccess.openAI(apiKey: "secret").checkAvailability(of: "gpt-5", transport: transport)
                .kind == nil)
        #expect(try await local.checkAvailability(of: "gpt-6", transport: transport).kind == .modelNotFound)
        // A server that takes no key is sent none, for an empty one too.
        #expect(transport.requests.map { $0.headerFields[.authorization] } == ["Bearer secret", nil])
    }

    @Test("a server compatible with OpenAI that refuses a request without a key asks for one")
    func keylessServerAsksForAKey() async throws {
        let transport = ScriptedTransport(replies: [.init(#"{"error":{"message":"no"}}"#, status: .unauthorized)])
        let local = ModelAccess.openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: nil)

        #expect(try await local.checkAvailability(of: "qwen3", transport: transport).kind == .keyNeeded)
    }

    @Test(
        "Anthropic is asked for the model itself: its window, a refused key, or no such model",
        arguments: [
            (HTTPResponse.Status.ok, ModelUnavailability.Kind?.none),
            (.unauthorized, .keyRefused),
            (.notFound, .modelNotFound),
            (.internalServerError, .providerError),
        ] as [(HTTPResponse.Status, ModelUnavailability.Kind?)])
    func anthropic(status: HTTPResponse.Status, kind: ModelUnavailability.Kind?) async throws {
        let transport = ScriptedTransport(replies: [
            .init(#"{"id":"claude-sonnet","max_input_tokens":1000000,"max_tokens":128000}"#, status: status)
        ])

        let availability = try await ModelAccess.anthropic(apiKey: "secret")
            .checkAvailability(of: "claude-sonnet", transport: transport)

        #expect(availability.kind == kind)
        #expect(availability.details == (kind == nil ? ModelDetails(contextSize: 1_000_000) : nil))
        #expect(transport.requests.map(\.path) == ["/v1/models/claude-sonnet"])
    }

    @Test(
        "Gemini is asked for the model itself; a key it says isn't valid is refused",
        arguments: [
            (
                HTTPResponse.Status.ok, #"{"name":"models/gemini-pro","inputTokenLimit":1048576}"#,
                ModelUnavailability.Kind?.none
            ),
            (.badRequest, #"{"error":{"code":400,"details":[{"reason":"API_KEY_INVALID"}]}}"#, .keyRefused),
            (.badRequest, #"{"error":{"code":400,"details":[{"reason":"OTHER"}]}}"#, .providerError),
            (.forbidden, #"{"error":{"code":403}}"#, .keyRefused),
            (.notFound, #"{"error":{"code":404}}"#, .modelNotFound),
        ] as [(HTTPResponse.Status, String, ModelUnavailability.Kind?)])
    func gemini(status: HTTPResponse.Status, answer: String, kind: ModelUnavailability.Kind?) async throws {
        let transport = ScriptedTransport(replies: [.init(answer, status: status)])

        let availability = try await ModelAccess.gemini(apiKey: "secret")
            .checkAvailability(of: "gemini-pro", transport: transport)

        #expect(availability.kind == kind)
        #expect(availability.details == (kind == nil ? ModelDetails(contextSize: 1_048_576) : nil))
        #expect(transport.requests.map(\.path) == ["/v1beta/models/gemini-pro"])
    }

    @Test("a provider that can't be reached says so, with why")
    func anUnreachableProviderSaysSo() async throws {
        let availability = try await ModelAccess.anthropic(apiKey: "secret")
            .checkAvailability(of: "m", transport: Unreachable())

        let unavailability = try #require(availability.unavailability)
        #expect(unavailability.kind == .unreachable)
        #expect(unavailability.underlyingError is Unreachable.Failure)
    }

    @Test("a check cancelled while it asks throws, neither available nor not")
    func aCancelledCheckThrows() async throws {
        let transport = WaitingForCancellation(answer: #"{"id":"m"}"#)
        let check = Task {
            try await ModelAccess.anthropic(apiKey: "secret").checkAvailability(of: "m", transport: transport)
        }
        while !transport.started { try await Task.sleep(for: .milliseconds(1)) }
        check.cancel()

        await #expect(throws: CancellationError.self) { try await check.value }
    }

    #if canImport(FoundationModels)
        @Test("the system model says what the system says")
        func systemReasons() {
            #expect(ModelAccess.kind(of: .deviceNotEligible) == .deviceNotEligible)
            #expect(ModelAccess.kind(of: .appleIntelligenceNotEnabled) == .appleIntelligenceNotEnabled)
            #expect(ModelAccess.kind(of: .modelNotReady) == .notReady)
        }
    #endif

    #if Llama
        @Test("a llama.cpp model is available when its file is there")
        func llamaFile() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gguf")
            #expect(try await ModelAccess.llama(modelPath: file.path).checkAvailability(of: "m").kind == .modelNotFound)
            try Data().write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(try await ModelAccess.llama(modelPath: file.path).checkAvailability(of: "m").kind == nil)
        }
    #endif
}

/// Answers each request with the next of its replies, and keeps what it was sent.
private final class ScriptedTransport: HTTPTransport, Sendable {
    struct Reply: Sendable {
        let status: HTTPResponse.Status
        let body: String

        init(_ body: String, status: HTTPResponse.Status = .ok) {
            self.status = status
            self.body = body
        }
    }

    private let state: Mutex<(replies: [Reply], requests: [HTTPRequest], bodies: [Data])>

    init(replies: [Reply]) {
        state = Mutex((replies, [], []))
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var bodies: [Data] { state.withLock { $0.bodies } }

    @concurrent func send<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration?,
        responseHandler: @concurrent (HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        let reply = state.withLock { state in
            state.requests.append(request)
            state.bodies.append(body ?? Data())
            return state.replies.removeFirst()
        }
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(Data(reply.body.utf8))
            continuation.finish()
        }
        return try await responseHandler(HTTPResponse(status: reply.status), HTTPResponseBody(chunks))
    }
}

/// A transport whose requests fail on the way, as one to a server that isn't there does.
private struct Unreachable: HTTPTransport {
    struct Failure: Error {}

    @concurrent func send<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration?,
        responseHandler: @concurrent (HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        throw Failure()
    }
}

/// A transport whose first answer waits until its task is cancelled, then comes as if nothing
/// happened: a transport that doesn't stop for cancellation.
private final class WaitingForCancellation: HTTPTransport, Sendable {
    private let answer: String
    private let state = Mutex((started: false, sent: 0))

    init(answer: String) {
        self.answer = answer
    }

    var started: Bool { state.withLock { $0.started } }
    var sent: Int { state.withLock { $0.sent } }

    @concurrent func send<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration?,
        responseHandler: @concurrent (HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        state.withLock {
            $0.started = true
            $0.sent += 1
        }
        while !Task.isCancelled { await Task.yield() }
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(Data(answer.utf8))
            continuation.finish()
        }
        return try await responseHandler(HTTPResponse(status: .ok), HTTPResponseBody(chunks))
    }
}

extension ModelAvailability {
    /// What checking it learned, when it's available.
    fileprivate var details: ModelDetails? {
        if case .available(let details) = self { details } else { nil }
    }

    /// Why it's unavailable, when it is.
    fileprivate var unavailability: ModelUnavailability? {
        if case .unavailable(let unavailability) = self { unavailability } else { nil }
    }

    /// What's in the way, when something is.
    fileprivate var kind: ModelUnavailability.Kind? { unavailability?.kind }
}
