public import AnyLanguageModel
import HTTPTypes

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Where a provider's models are asked about, and how it's reached: listing asks what it offers;
/// checking asks whether one of them can be used now.
public enum ModelAccess: Sendable {
    /// An Ollama server: one of your own, which takes no key, or Ollama's cloud, which does.
    case ollama(baseURL: URL, apiKey: String?)
    /// A server compatible with OpenAI's API, with its key, or none for one that takes none.
    case openAICompatible(baseURL: URL, apiKey: String?)
    case openAI(apiKey: String)
    case anthropic(apiKey: String)
    case gemini(apiKey: String)
    /// Apple's on-device model.
    case system
    #if Llama
        /// A GGUF file llama.cpp loads.
        case llama(modelPath: String)
    #endif
}

// MARK: - Available Models

extension ModelAccess {
    /// The models it offers, by the IDs a model is made with, through `transport`: Apple's
    /// on-device model is its one model; a GGUF file is whichever model it holds.
    ///
    /// - Throws: ``ModelUnavailability``, when the key is missing or refused, the provider can't be
    ///   reached, or it answers something else; `CancellationError`, when it's cancelled.
    public func availableModels(transport: any HTTPTransport = makeDefaultTransport()) async throws -> [String] {
        switch self {
        case .ollama(let baseURL, let apiKey):
            // Ollama's cloud lists its models to anyone, so this doesn't check the key: checking does.
            return try await Self.asking(keyGiven: apiKey != nil) {
                let list: ModelNames = try await transport.answer(
                    HTTPRequest(
                        method: .get, url: baseURL.appendingPathComponent("api/tags"),
                        headerFields: Self.bearer(apiKey)))
                return list.models.map(\.name)
            }
        case .openAICompatible(let baseURL, let apiKey):
            return try await Self.openAIModels(at: baseURL, apiKey: apiKey, transport: transport)
        case .openAI(let apiKey):
            return try await Self.openAIModels(
                at: OpenAILanguageModel.defaultBaseURL, apiKey: apiKey, transport: transport)
        case .anthropic(let apiKey):
            return try await Self.asking(keyGiven: !apiKey.isEmpty) {
                var models: [String] = []
                var after: String?
                while true {
                    // A transport may not stop for cancellation, so it's checked before each page.
                    try Task.checkCancellation()
                    var query = [URLQueryItem(name: "limit", value: "1000")]
                    if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
                    let page: AnthropicModelPage = try await transport.answer(
                        HTTPRequest(
                            method: .get,
                            url: try AnthropicLanguageModel.defaultBaseURL.appendingPathComponent("v1/models")
                                .asking(query),
                            headerFields: Self.anthropicHeaders(apiKey)))
                    models += page.data.map(\.id)
                    // The next page, unless this was the last, or its cursor didn't move.
                    guard page.hasMore, let last = page.lastID, last != after else { return models }
                    after = last
                }
            }
        case .gemini(let apiKey):
            return try await Self.asking(keyGiven: !apiKey.isEmpty, refusesKey: Self.geminiRefusesKey) {
                var models: [String] = []
                var token: String?
                while true {
                    // A transport may not stop for cancellation, so it's checked before each page.
                    try Task.checkCancellation()
                    var query = [URLQueryItem(name: "pageSize", value: "1000")]
                    if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
                    let page: GeminiModelPage = try await transport.answer(
                        HTTPRequest(
                            method: .get,
                            url: try Self.geminiModels.asking(query),
                            headerFields: Self.geminiHeaders(apiKey)))
                    // Only those that generate content: not embedding models.
                    models += (page.models ?? [])
                        .filter { $0.supportedGenerationMethods?.contains("generateContent") == true }
                        .map(\.id)
                    // The next page, unless this was the last, or its token didn't change.
                    guard let next = page.nextPageToken, !next.isEmpty, next != token else { return models }
                    token = next
                }
            }
        case .system:
            return ["default"]
        #if Llama
            case .llama:
                return []
        #endif
        }
    }

    /// The models a server compatible with OpenAI's API lists for `apiKey`: `GET models`.
    private static func openAIModels(at baseURL: URL, apiKey: String?, transport: any HTTPTransport)
        async throws -> [String]
    {
        try await asking(keyGiven: !(apiKey ?? "").isEmpty) {
            let list: OpenAIModelList = try await transport.answer(
                HTTPRequest(method: .get, url: baseURL.appendingPathComponent("models"), headerFields: bearer(apiKey)))
            return list.data.map(\.id)
        }
    }

    /// What `body` asks a provider, with a failure read as what it says.
    private static func asking<Answer>(
        keyGiven: Bool,
        refusesKey: (HTTPTransportError) -> Bool = { _ in false },
        _ body: () async throws -> Answer
    ) async throws -> Answer {
        do {
            return try await body()
        } catch {
            throw try ModelUnavailability(
                asking: error, keyGiven: keyGiven, missingModel: false, refusesKey: refusesKey)
        }
    }
}

// MARK: - Checking Availability

extension ModelAccess {
    /// Whether `model` can be used now, asked through `transport`: a provider, whether it takes the
    /// key and has the model; this device, whether it can run it. When it can, what checking it
    /// learned, such as the model's context size.
    public func checkAvailability(of model: String, transport: any HTTPTransport = makeDefaultTransport())
        async throws(CancellationError) -> ModelAvailability
    {
        do {
            return .available(try await details(of: model, transport: transport))
        } catch let unavailability as ModelUnavailability {
            return .unavailable(unavailability)
        } catch {
            // Every failure is read as unavailability, so anything else is the check cancelled.
            throw CancellationError()
        }
    }

    /// What checking `model` learns about it, or why it can't be used.
    private func details(of model: String, transport: any HTTPTransport) async throws -> ModelDetails {
        switch self {
        case .ollama(let baseURL, let apiKey):
            // A key is checked by the account Ollama's cloud answers for it; without one, no account
            // is asked for, as a server of your own takes none.
            if let apiKey {
                try await Self.asking(keyGiven: true) {
                    let _: OllamaAccount = try await transport.answer(
                        HTTPRequest(
                            method: .post, url: baseURL.appendingPathComponent("api/me"),
                            headerFields: Self.bearer(apiKey)))
                }
            }
            // The model, as `api/show` says, whatever tag it's named with.
            do {
                let shown: OllamaShownModel = try await transport.answer(
                    HTTPRequest(
                        method: .post, url: baseURL.appendingPathComponent("api/show"),
                        headerFields: Self.bearer(apiKey)),
                    body: try JSONEncoder().encode(["model": model]))
                return ModelDetails(contextSize: shown.contextLength)
            } catch {
                throw try ModelUnavailability(asking: error, keyGiven: apiKey != nil, missingModel: true)
            }
        case .openAICompatible, .openAI:
            // Whether the server lists it, for this key: OpenAI and most servers compatible with it
            // say nothing more about a model.
            guard try await availableModels(transport: transport).contains(model) else {
                throw ModelUnavailability(kind: .modelNotFound)
            }
            return ModelDetails()
        case .anthropic(let apiKey):
            do {
                let found: AnthropicModelPage.Model = try await transport.answer(
                    HTTPRequest(
                        method: .get,
                        url: AnthropicLanguageModel.defaultBaseURL.appendingPathComponent("v1/models")
                            .appendingPathComponent(model),
                        headerFields: Self.anthropicHeaders(apiKey)))
                return ModelDetails(contextSize: found.maxInputTokens)
            } catch {
                throw try ModelUnavailability(asking: error, keyGiven: !apiKey.isEmpty, missingModel: true)
            }
        case .gemini(let apiKey):
            do {
                let found: GeminiModelPage.Model = try await transport.answer(
                    HTTPRequest(
                        method: .get, url: Self.geminiModels.appendingPathComponent(model),
                        headerFields: Self.geminiHeaders(apiKey)))
                return ModelDetails(contextSize: found.inputTokenLimit)
            } catch {
                throw try ModelUnavailability(
                    asking: error, keyGiven: !apiKey.isEmpty, missingModel: true, refusesKey: Self.geminiRefusesKey)
            }
        case .system:
            #if canImport(FoundationModels)
                let system = FoundationModels.SystemLanguageModel.default
                switch system.availability {
                case .available:
                    return ModelDetails(contextSize: system.contextSize)
                case .unavailable(let reason):
                    throw ModelUnavailability(kind: Self.kind(of: reason))
                }
            #else
                throw ModelUnavailability(kind: .deviceNotEligible)
            #endif
        #if Llama
            case .llama(let modelPath):
                guard FileManager.default.fileExists(atPath: modelPath) else {
                    throw ModelUnavailability(kind: .modelNotFound)
                }
                return ModelDetails()
        #endif
        }
    }

    #if canImport(FoundationModels)
        /// What the system's `reason` is, as availability is checked.
        static func kind(of reason: FoundationModels.SystemLanguageModel.Availability.UnavailableReason)
            -> ModelUnavailability.Kind
        {
            switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
            case .modelNotReady: .notReady
            @unknown default: .other
            }
        }
    #endif
}

// MARK: - Providers' requests and answers

extension ModelAccess {
    /// `apiKey` as a bearer token: none without one, or for an empty one.
    private static func bearer(_ apiKey: String?) -> HTTPFields {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        return [.authorization: "Bearer \(apiKey)"]
    }

    /// Anthropic's key and API version.
    private static func anthropicHeaders(_ apiKey: String) -> HTTPFields {
        [
            HTTPField.Name("x-api-key")!: apiKey,
            HTTPField.Name("anthropic-version")!: AnthropicLanguageModel.defaultAPIVersion,
        ]
    }

    /// Gemini's key.
    private static func geminiHeaders(_ apiKey: String) -> HTTPFields {
        [HTTPField.Name("x-goog-api-key")!: apiKey]
    }

    /// Gemini's models, under its API version.
    private static var geminiModels: URL {
        GeminiLanguageModel.defaultBaseURL.appendingPathComponent(GeminiLanguageModel.defaultAPIVersion)
            .appendingPathComponent("models")
    }

    /// Whether `error` is Gemini refusing a key that isn't valid: `400 Bad Request`, naming the reason.
    private static func geminiRefusesKey(_ error: HTTPTransportError) -> Bool {
        guard error.response?.status == .badRequest, let body = error.body,
            let answer = try? JSONDecoder().decode(GeminiErrorAnswer.self, from: body)
        else { return false }
        return answer.error.details?.contains { $0.reason == "API_KEY_INVALID" } ?? false
    }
}

/// The answer to Ollama's `api/tags`.
private struct ModelNames: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

/// The answer to Ollama's `api/me`: the account a key is for. Only that it answers is read.
private struct OllamaAccount: Decodable {}

/// The answer to Ollama's `api/show`: what's read of it is the model's context length.
private struct OllamaShownModel: Decodable {
    /// The model's metadata, its keys named by its architecture: `llama.context_length`.
    let modelInfo: [String: JSONValue]?

    /// The most tokens the model was made for, as its architecture's `context_length` says.
    var contextLength: Int? {
        modelInfo?.first { $0.key.hasSuffix(".context_length") }?.value.intValue
    }

    private enum CodingKeys: String, CodingKey {
        case modelInfo = "model_info"
    }
}

/// The answer to `GET models` of a server compatible with OpenAI.
private struct OpenAIModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

/// A page of Anthropic's `GET /v1/models`, or one model of it.
private struct AnthropicModelPage: Decodable {
    struct Model: Decodable {
        let id: String
        /// The most tokens the model takes as input: its context window.
        let maxInputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case maxInputTokens = "max_input_tokens"
        }
    }

    let data: [Model]
    let hasMore: Bool
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// A page of Gemini's `GET models`, or one model of it.
private struct GeminiModelPage: Decodable {
    struct Model: Decodable {
        /// Its resource name: `models/` and its ID.
        let name: String
        let supportedGenerationMethods: [String]?
        /// The most tokens its input may take.
        let inputTokenLimit: Int?

        /// What a model is made with: its name without `models/`.
        var id: String {
            name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }

    /// Its models: none, when an account has none.
    let models: [Model]?
    let nextPageToken: String?
}

/// Gemini's answer to a request it refuses.
private struct GeminiErrorAnswer: Decodable {
    struct Failure: Decodable {
        struct Detail: Decodable {
            let reason: String?
        }

        let details: [Detail]?
    }

    let error: Failure
}

extension URL {
    /// This address asking `query`.
    fileprivate func asking(_ query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            throw HTTPTransportError(kind: .invalidRequest)
        }
        components.queryItems = (components.queryItems ?? []) + query
        guard let url = components.url else { throw HTTPTransportError(kind: .invalidRequest) }
        return url
    }
}

extension HTTPTransport {
    /// `request`'s answer, decoded from JSON: an answer that isn't a success throws its status and
    /// body, as AnyLanguageModel's providers do.
    fileprivate func answer<Answer: Decodable>(_ request: HTTPRequest, body: Data? = nil) async throws -> Answer {
        var request = request
        request.headerFields[.accept] = "application/json"
        if body != nil { request.headerFields[.contentType] = "application/json" }
        let data = try await send(request: request, body: body, timeout: nil) { response, answer in
            let data = try await answer.collect()
            guard response.status.kind == .successful else {
                throw HTTPTransportError(kind: .httpError, response: response, body: data)
            }
            return data
        }
        // A body cut short by cancelling isn't read as a whole one.
        try Task.checkCancellation()
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw HTTPTransportError(kind: .decodingError, underlyingError: error)
        }
    }
}
