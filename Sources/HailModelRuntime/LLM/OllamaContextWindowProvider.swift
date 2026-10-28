import AsyncHTTPClient
import Foundation

/// Errors raised while reading Ollama's model metadata.
public enum OllamaContextWindowError: Error, Sendable, Equatable {
    case invalidResponse
    case requestFailed(String)
    case missingContextLength
    case invalidContextLength(Int)
}

/// Reads the effective context capacity reported by Ollama for a model.
///
/// Ollama exposes runner metadata through `POST /api/show`. The model-info
/// key is architecture-specific (for example, `llama.context_length`), so
/// this adapter deliberately searches the returned metadata rather than
/// baking a model-family name into the runtime.
public enum OllamaContextWindowProvider {
    /// The most of `/api/show`'s answer that's read.
    private static let maximumResponseBytes = 16 * 1024 * 1024

    public static func resolve(
        model: String,
        baseURL: URL
    ) async throws(OllamaContextWindowError) -> Int {
        var request = HTTPClientRequest(url: baseURL.appendingPathComponent("api/show").absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        do {
            request.body = .bytes(try JSONSerialization.data(withJSONObject: ["model": model], options: []))
        } catch {
            throw .requestFailed(String(describing: error))
        }

        do {
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(10))
            guard (200..<300).contains(response.status.code) else {
                throw OllamaContextWindowError.invalidResponse
            }
            let body = try await response.body.collect(upTo: maximumResponseBytes)

            let object = try JSONSerialization.jsonObject(with: Data(body.readableBytesView))
            guard let contextLength = contextLength(in: object) else {
                throw OllamaContextWindowError.missingContextLength
            }
            guard contextLength > 0 else {
                throw OllamaContextWindowError.invalidContextLength(contextLength)
            }
            return contextLength
        } catch let error as OllamaContextWindowError {
            throw error
        } catch {
            throw .requestFailed(String(describing: error))
        }
    }

    private static func contextLength(in value: Any) -> Int? {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let normalized = key.lowercased()
                if normalized == "context_length" || normalized.hasSuffix(".context_length") {
                    if let number = nested as? NSNumber {
                        return number.intValue
                    }
                    if let number = nested as? Int {
                        return number
                    }
                }
                if let nestedLength = contextLength(in: nested) {
                    return nestedLength
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let nestedLength = contextLength(in: nested) {
                    return nestedLength
                }
            }
        }
        return nil
    }
}
