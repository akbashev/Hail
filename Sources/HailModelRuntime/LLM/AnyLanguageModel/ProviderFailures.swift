import AnyLanguageModel
import HTTPTypes
import HailCore

import struct AsyncHTTPClient.HTTPClientError
import struct Foundation.URLError

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How a provider says a request failed, read where its endpoint is made. HTTP's own meaning,
/// a status and its `Retry-After`, is the same for every provider; how a provider says a request
/// was longer than its context is its own, in the body of its error.
public struct ProviderFailures: Sendable {
    /// What the body of the provider's error says when a request is longer than its context.
    let contextExceeded: [String]

    public init(contextExceeded: [String]) {
        self.contextExceeded = contextExceeded
    }

    public static let ollama = Self(contextExceeded: ["exceed_context_size_error"])
    public static let openAI = Self(contextExceeded: ["context_length_exceeded"])
    /// Servers that answer as OpenAI does, and say it in their own words too.
    public static let openAICompatible = Self(contextExceeded: ["context_length_exceeded", "maximum context length"])
    public static let anthropic = Self(contextExceeded: ["prompt is too long"])
    public static let gemini = Self(contextExceeded: ["exceeds the maximum number of tokens"])
    /// A model in this process, which says why a request failed in its own Swift errors.
    public static let swiftErrors = Self(contextExceeded: [])
}

/// What a failed request means for asking it again.
enum RequestFailure: Equatable {
    /// It failed: asking again would fail the same way.
    case failed(ModelEndpointError)
    /// The provider is busy, and takes it again after `retryAfter`, when it says.
    case busy(ModelEndpointError, retryAfter: Duration?)
    /// It didn't reach the model, and is asked again as it was.
    case unreached(ModelEndpointError)
}

extension ProviderFailures {
    func read(_ error: any Error) -> RequestFailure {
        if Task.isCancelled || error is CancellationError
            || (error as? HTTPClientError) == .cancelled
            || (error as? URLError)?.code == .cancelled
        {
            return .failed(.cancelled)
        }
        if let error = error as? ModelEndpointError { return .failed(error) }
        if let error = error as? HTTPTransportError, error.kind == .httpError, let response = error.response {
            return read(response, body: error.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .failed(.contextLengthExceeded)
            case .rateLimited: return .busy(.rateLimit, retryAfter: nil)
            case .decodingFailure(let context): return .failed(.decodingError(context.debugDescription))
            default: break
            }
        }
        if let error = error as? LlamaLanguageModelError, error == .promptExceedsContextWindow {
            return .failed(.contextLengthExceeded)
        }
        if Self.isUnreached(error) { return .unreached(.requestFailed(String(describing: error))) }
        return .failed(.requestFailed(String(describing: error)))
    }

    private func read(_ response: HTTPResponse, body: String) -> RequestFailure {
        let failure = ModelEndpointError.requestFailed("HTTP \(response.status.code): \(body)")
        switch response.status.code {
        case 401, 403:
            return .failed(.authentication)
        case 429:
            return .busy(.rateLimit, retryAfter: Self.retryAfter(response))
        case 502, 503, 504, 529:
            return .busy(.unavailable, retryAfter: Self.retryAfter(response))
        default:
            if contextExceeded.contains(where: body.localizedCaseInsensitiveContains) {
                return .failed(.contextLengthExceeded)
            }
            return .failed(failure)
        }
    }

    /// The wait a response's `Retry-After` asks for, in seconds or until a date.
    static func retryAfter(_ response: HTTPResponse) -> Duration? {
        guard let value = response.headerFields[.retryAfter]?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = Int(value) { return .seconds(max(seconds, 0)) }
        guard let date = try? Date(value, strategy: Self.httpDate) else { return nil }
        return .seconds(max(date.timeIntervalSinceNow, 0))
    }

    private static let httpDate = Date.ParseStrategy(
        format:
            "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .padded(4)) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(identifier: "GMT")!
    )

    private static func isUnreached(_ error: any Error) -> Bool {
        if let error = error as? HTTPClientError {
            return error == .deadlineExceeded || error == .readTimeout
                || error == .writeTimeout || error == .connectTimeout
                || error == .remoteConnectionClosed
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }
}
