import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The two sources of a model's effective context capacity.
///
/// `configured` is the pure, host-owned override. `discovered` is the
/// effectful fallback used when no override exists. Keeping them together
/// makes the precedence rule part of the capability instead of making the
/// router coordinate unrelated configuration values.
public struct ModelContextWindowResolver: Sendable {
    public typealias Configured = @Sendable (AgentModelRoute) -> Int?
    public typealias Discovered =
        @Sendable (AgentModelRoute, URL) async throws -> Int?

    private let configured: Configured
    private let discovered: Discovered

    public init(
        configured: @escaping Configured = { _ in nil },
        discovered: @escaping Discovered = { _, _ in nil }
    ) {
        self.configured = configured
        self.discovered = discovered
    }

    func configuredValue(for route: AgentModelRoute) -> Int? {
        configured(route)
    }

    public func resolve(
        for route: AgentModelRoute,
        baseURL: URL
    ) async throws -> Int? {
        if let value = configured(route) {
            return value
        }
        return try await discovered(route, baseURL)
    }
}

/// Host-owned policy used by ``ModelRouter`` when constructing built-in
/// provider endpoints. Hail deliberately does not read provider environment
/// variables, select API keys, or invent provider URLs here; applications
/// resolve those values and pass them in at composition time.
public struct ModelRouterConfiguration: Sendable {
    public let temperature: Double
    public let apiKeys: [AgentModelProvider: String]
    public let baseURLs: [AgentModelProvider: URL]
    /// The host-owned effective context-window capability.
    public let contextWindowResolver: ModelContextWindowResolver
    /// Host-verified reasoning capabilities keyed by a complete model
    /// reference. An absent entry means that capability is unknown, not that
    /// the model supports no effort levels. A level's encoding can translate
    /// a generic effort into a provider-specific control (for example,
    /// Gemini's dynamic thinking mode).
    public let reasoningCapabilities: [AgentModelReference: ModelReasoningCapabilities]

    public init(
        temperature: Double,
        apiKeys: [AgentModelProvider: String] = [:],
        baseURLs: [AgentModelProvider: URL] = [:],
        contextWindows: [AgentModelProvider: Int] = [:],
        modelContextWindows: [AgentModelReference: Int] = [:],
        contextWindowResolver: ModelContextWindowResolver? = nil,
        reasoningCapabilities: [AgentModelReference: ModelReasoningCapabilities] = [:]
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
        for (model, window) in modelContextWindows where window <= 0 {
            throw .invalidModelContextWindow(model, window)
        }
        for (model, capabilities) in reasoningCapabilities {
            var seenEfforts = Set<ReasoningEffort>()
            for level in capabilities.levels {
                guard seenEfforts.insert(level.effort).inserted else {
                    throw .duplicateReasoningEffort(model, level.effort)
                }
                if case .tokenBudget(let budget) = level.encoding, budget <= 0 {
                    throw .invalidReasoningTokenBudget(model, budget)
                }
            }
        }
        self.temperature = temperature
        self.apiKeys = normalizedAPIKeys
        self.baseURLs = baseURLs
        self.contextWindowResolver =
            contextWindowResolver
            ?? ModelContextWindowResolver(
                configured: { route in
                    modelContextWindows[AgentModelReference(route: route)]
                        ?? contextWindows[route.provider]
                }
            )
        self.reasoningCapabilities = reasoningCapabilities
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

    func configuredContextWindow(for route: AgentModelRoute) -> Int? {
        contextWindowResolver.configuredValue(for: route)
    }

    func validate(
        reasoning: ReasoningEffortSelection?,
        for route: AgentModelRoute
    ) throws(ModelRouterError) {
        guard let reasoning,
            let capabilities = reasoningCapabilities[AgentModelReference(route: route)]
        else {
            return
        }
        guard capabilities.supports(reasoning.effort) else {
            throw .unsupportedReasoningEffort(
                provider: route.provider,
                model: route.model,
                effort: reasoning.effort
            )
        }
    }

    func selection(
        for reasoningEffort: ReasoningEffort?,
        route: AgentModelRoute
    ) -> ReasoningEffortSelection? {
        guard let reasoningEffort else { return nil }
        guard let capabilities = reasoningCapabilities[AgentModelReference(route: route)] else {
            return ReasoningEffortSelection(effort: reasoningEffort)
        }
        return ReasoningEffortSelection(
            effort: reasoningEffort,
            encoding: capabilities.encoding(for: reasoningEffort) ?? .raw
        )
    }
}

public enum ModelRouterConfigurationError: Error, Sendable, Equatable {
    case invalidTemperature(Double)
    case emptyAPIKey(AgentModelProvider)
    case invalidBaseURL(AgentModelProvider, String)
    case invalidContextWindow(AgentModelProvider, Int)
    case invalidModelContextWindow(AgentModelReference, Int)
    case duplicateReasoningEffort(AgentModelReference, ReasoningEffort)
    case invalidReasoningTokenBudget(AgentModelReference, Int)
}

public enum ModelRouterError: Error, Sendable, Equatable {
    case invalidRoute(AgentModelRouteError)
    case unsupportedProvider(String)
    case missingAPIKey(AgentModelProvider)
    case missingProviderConfiguration(AgentModelProvider)
    case contextWindowUnavailable(AgentModelProvider, String, String)
    /// The host capability profile rejected the level, or the selected
    /// built-in adapter has no representation for its configured encoding.
    case unsupportedReasoningEffort(
        provider: AgentModelProvider,
        model: String,
        effort: ReasoningEffort
    )
    case missingWorkingDirectory
    case invalidEnvironmentValue(key: String, value: String)
}
