import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Host-owned policy used by ``ModelRouter`` when constructing built-in
/// provider endpoints. Hail deliberately does not read provider environment
/// variables, select API keys, or invent provider URLs here; applications
/// resolve those values and pass them in at composition time.
public struct ModelRouterConfiguration: Sendable {
    public let temperature: Double
    public let apiKeys: [AgentModelProvider: String]
    public let baseURLs: [AgentModelProvider: URL]
    public let contextWindows: [AgentModelProvider: Int]

    public init(
        temperature: Double,
        apiKeys: [AgentModelProvider: String] = [:],
        baseURLs: [AgentModelProvider: URL] = [:],
        contextWindows: [AgentModelProvider: Int] = [:]
    ) throws(ModelRouterConfigurationError) {
        guard temperature.isFinite, temperature >= 0 else {
            throw .invalidTemperature(temperature)
        }
        var normalizedAPIKeys: [AgentModelProvider: String] = [:]
        for (provider, key) in apiKeys {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw .emptyAPIKey(provider)
            }
            normalizedAPIKeys[provider] = normalized
        }
        for (provider, url) in baseURLs {
            guard let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host != nil
            else {
                throw .invalidBaseURL(provider, url.absoluteString)
            }
        }
        for (provider, window) in contextWindows where window <= 0 {
            throw .invalidContextWindow(provider, window)
        }
        self.temperature = temperature
        self.apiKeys = normalizedAPIKeys
        self.baseURLs = baseURLs
        self.contextWindows = contextWindows
    }

    func apiKey(for provider: AgentModelProvider) throws(ModelRouterError) -> String {
        guard let value = apiKeys[provider] else {
            throw .missingAPIKey(provider)
        }
        return value
    }

    func baseURL(for provider: AgentModelProvider) throws(ModelRouterError) -> URL {
        guard let value = baseURLs[provider] else {
            throw .missingProviderConfiguration(provider)
        }
        return value
    }

    func contextWindow(for provider: AgentModelProvider) -> Int? {
        contextWindows[provider]
    }
}

public enum ModelRouterConfigurationError: Error, Sendable, Equatable {
    case invalidTemperature(Double)
    case emptyAPIKey(AgentModelProvider)
    case invalidBaseURL(AgentModelProvider, String)
    case invalidContextWindow(AgentModelProvider, Int)
}

public enum ModelRouterError: Error, Sendable, Equatable {
    case invalidRoute(AgentModelRouteError)
    case unsupportedProvider(String)
    case missingAPIKey(AgentModelProvider)
    case missingProviderConfiguration(AgentModelProvider)
    case missingProjectRoot
    case invalidEnvironmentValue(key: String, value: String)
}
