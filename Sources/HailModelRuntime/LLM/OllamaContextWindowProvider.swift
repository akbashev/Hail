#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    public static func resolve(
        model: String,
        baseURL: URL
    ) async throws(OllamaContextWindowError) -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["model": model],
                options: []
            )
        } catch {
            throw .requestFailed(String(describing: error))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else {
                throw OllamaContextWindowError.invalidResponse
            }

            let object = try JSONSerialization.jsonObject(with: data)
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
