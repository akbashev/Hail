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
    public typealias Configured = @Sendable (AgentModel, AgentID) async -> Int?
    public typealias Discovered =
        @Sendable (AgentModel, URL) async throws -> Int?

    private let configured: Configured
    private let discovered: Discovered

    public init(
        configured: @escaping Configured = { _, _ in nil },
        discovered: @escaping Discovered = { _, _ in nil }
    ) {
        self.configured = configured
        self.discovered = discovered
    }

    func configuredValue(for model: AgentModel, agentID: AgentID) async -> Int? {
        await configured(model, agentID)
    }

    public func resolve(
        for model: AgentModel,
        baseURL: URL,
        agentID: AgentID
    ) async throws -> Int? {
        if let value = await configured(model, agentID) {
            return value
        }
        return try await discovered(model, baseURL)
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
    /// identifier. An absent entry means that capability is unknown, not that
    /// the model supports no effort levels. A level's encoding can translate
    /// a generic effort into a provider-specific control (for example,
    /// Gemini's dynamic thinking mode).
    public let reasoningCapabilities: [AgentModel: ModelReasoningCapabilities]

    public init(
        temperature: Double,
        apiKeys: [AgentModelProvider: String] = [:],
        baseURLs: [AgentModelProvider: URL] = [:],
        contextWindows: [AgentModelProvider: Int] = [:],
        modelContextWindows: [AgentModel: Int] = [:],
        contextWindowResolver: ModelContextWindowResolver? = nil,
        reasoningCapabilities: [AgentModel: ModelReasoningCapabilities] = [:]
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
                configured: { model, _ in
                    modelContextWindows[model]
                        ?? contextWindows[model.provider]
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

    func configuredContextWindowForAgent(
        _ agentID: AgentID,
        model: AgentModel
    ) async -> Int? {
        await contextWindowResolver.configuredValue(for: model, agentID: agentID)
    }

    func contextWindow(for model: AgentModel, agentID: AgentID) async -> Int? {
        await configuredContextWindowForAgent(agentID, model: model)
    }

    func validate(
        reasoning: ReasoningEffortSelection?,
        for model: AgentModel
    ) throws(ModelRouterError) {
        guard let reasoning,
            let capabilities = reasoningCapabilities[model]
        else {
            return
        }
        guard capabilities.supports(reasoning.effort) else {
            throw .unsupportedReasoningEffort(
                provider: model.provider,
                model: model.id.rawValue,
                effort: reasoning.effort
            )
        }
    }

    func selection(
        for reasoningEffort: ReasoningEffort?,
        model: AgentModel
    ) -> ReasoningEffortSelection? {
        guard let reasoningEffort else { return nil }
        guard let capabilities = reasoningCapabilities[model] else {
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
    case invalidModelContextWindow(AgentModel, Int)
    case duplicateReasoningEffort(AgentModel, ReasoningEffort)
    case invalidReasoningTokenBudget(AgentModel, Int)
}

public enum ModelRouterError: Error, Sendable, Equatable {
    case invalidModel(AgentModelError)
    case unsupportedProvider(String)
    case missingAPIKey(AgentModelProvider)
    case missingProviderConfiguration(AgentModelProvider)
    case endpointProviderFailed(AgentModelProvider, String)
    case contextWindowUnavailable(AgentModelProvider, String, String)
    /// The host capability profile rejected the level, or the selected
    /// built-in adapter has no representation for its configured encoding.
    case unsupportedReasoningEffort(
        provider: AgentModelProvider,
        model: String,
        effort: ReasoningEffort
    )
}
