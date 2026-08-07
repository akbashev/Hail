import AnyLanguageModel
import HailCore
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Resolves model identifiers to reusable ``ModelEndpoint`` instances.
///
/// Endpoints are cached per (model, agentID, contextID) so that expensive
/// long-lived connections (e.g. the local `kimi-code` ACP session) are created
/// once and shared across agents that target the same configuration.
public actor ModelRouter {
    private let projectRootPath: String?
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let modelEndpointProvider: ModelEndpointProvider?
    private var cache: [CacheKey: any ModelEndpoint] = [:]

    private struct CacheKey: Hashable, Sendable {
        let model: String
        let agentID: String
        let contextID: AgentContextID?
        let workingDirectory: String
        let executionPolicy: AgentExecutionPolicy
    }

    public init(
        projectRootPath: String? = nil,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        modelEndpointProvider: ModelEndpointProvider? = nil
    ) {
        self.projectRootPath = projectRootPath
        self.mcpServerConfiguration = mcpServerConfiguration
        self.modelEndpointProvider = modelEndpointProvider
    }

    /// Returns the cached ``ModelEndpoint`` for the given configuration,
    /// creating and caching it if necessary.
    ///
    /// The caller owns the streaming effect; this router only resolves and
    /// caches the endpoint instance. `resumeSession` and `authority` are used
    /// only when a new endpoint is created — a cached endpoint already owns
    /// its live session and authority.
    public func endpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil
    ) throws(ModelRouterError) -> any ModelEndpoint {
        try cachedEndpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority
        )
    }

    private func cachedEndpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil
    ) throws(ModelRouterError) -> any ModelEndpoint {
        guard let effectiveWorkingDirectory = workingDirectory ?? projectRootPath else {
            throw ModelRouterError.missingProjectRoot
        }
        let key = CacheKey(
            model: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: effectiveWorkingDirectory,
            executionPolicy: executionPolicy
        )

        if let cached = cache[key] {
            return cached
        }

        let endpoint = try makeEndpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: effectiveWorkingDirectory,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority
        )
        cache[key] = endpoint
        return endpoint
    }

    /// Removes the cached endpoint for the given configuration, tearing down
    /// its live harness session if it owns one (killing the subprocess).
    ///
    /// Called when the owning agent deactivates: the cache pins endpoints
    /// independently of actor lifetime, so without eviction a passivated agent
    /// would keep an idle harness process alive forever. The next
    /// ``endpoint(for:agentID:contextID:workingDirectory:executionPolicy:resumeSession:authority:)``
    /// call rebuilds the endpoint cold, resuming from the journaled session.
    public func evict(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace
    ) async {
        guard let effectiveWorkingDirectory = workingDirectory ?? projectRootPath else { return }
        let key = CacheKey(
            model: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: effectiveWorkingDirectory,
            executionPolicy: executionPolicy
        )
        guard let endpoint = cache.removeValue(forKey: key) else { return }
        if let sessionOwning = endpoint as? SessionOwningEndpoint {
            await sessionOwning.terminateSession()
        }
    }

    public func register<E: ModelEndpoint>(
        _ endpoint: E,
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workingDirectory: String? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace
    ) throws(ModelRouterError) {
        guard let effectiveWorkingDirectory = workingDirectory ?? projectRootPath else {
            throw ModelRouterError.missingProjectRoot
        }
        let key = CacheKey(
            model: model,
            agentID: agentID,
            contextID: contextID,
            workingDirectory: effectiveWorkingDirectory,
            executionPolicy: executionPolicy
        )
        cache[key] = endpoint
    }

    /// Returns the model identifier that would be used after provider rewriting.
    /// Useful for tests that want to verify routing decisions without executing
    /// a stream.
    public func resolvedModelIdentifier(for model: String) -> String {
        effectiveModelIdentifier(model)
    }

    /// Returns the model identifier that should actually be used.
    ///
    /// Empty strings are rewritten to the shared default.
    private func effectiveModelIdentifier(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultAgentModel
        }
        return trimmed
    }

    private func makeEndpoint(
        for model: String,
        agentID: String?,
        contextID: AgentContextID?,
        workingDirectory: String,
        executionPolicy: AgentExecutionPolicy,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil
    ) throws(ModelRouterError) -> any ModelEndpoint {
        let effectiveModel = effectiveModelIdentifier(model)
        if let endpoint = modelEndpointProvider?(
            ModelEndpointRequest(
                model: effectiveModel,
                agentID: agentID,
                contextID: contextID,
                workingDirectory: workingDirectory,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority
            )
        ) {
            return endpoint
        }
        let parts = effectiveModel.split(separator: "/")
        let provider = parts.first.map(String.init) ?? effectiveModel
        let modelName = parts.dropFirst().joined(separator: "/")
        let providerContextLabel = contextID?.rawValue

        switch provider {
        case "codex":
            return CodexAppServerEndpoint(
                model: modelName.isEmpty ? "gpt-5.6-sol" : modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority
            )

        case "kimi-code":
            return KimiCodeEndpoint(
                model: modelName.isEmpty ? "kimi-for-coding" : modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority
            )

        case "claude":
            // An empty model name defers to the user's own `claude` CLI default
            // model rather than forcing one here.
            return ClaudeCliEndpoint(
                model: modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority
            )

        case "moonshot":
            guard let apiKey = ProcessInfo.processInfo.environment["MOONSHOT_API_KEY"] else {
                throw ModelRouterError.missingAPIKey("MOONSHOT_API_KEY")
            }
            return AnyLanguageModelEndpoint(
                languageModel: OpenAILanguageModel(
                    baseURL: URL(string: "https://api.moonshot.ai/v1/")!,
                    apiKey: apiKey,
                    model: modelName.isEmpty ? "kimi-k2.5" : modelName
                ),
                modelIdentifier: modelName.isEmpty ? "kimi-k2.5" : modelName,
                temperature: 0.7
            )

        case "openai":
            guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
                throw ModelRouterError.missingAPIKey("OPENAI_API_KEY")
            }
            return AnyLanguageModelEndpoint(
                languageModel: OpenAILanguageModel(
                    apiKey: apiKey,
                    model: modelName.isEmpty ? "gpt-5.5" : modelName
                ),
                modelIdentifier: modelName.isEmpty ? "gpt-5.5" : modelName,
                temperature: 0.7
            )

        case "anthropic":
            guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
                throw ModelRouterError.missingAPIKey("ANTHROPIC_API_KEY")
            }
            return AnyLanguageModelEndpoint(
                languageModel: AnthropicLanguageModel(
                    apiKey: apiKey,
                    model: modelName.isEmpty ? "claude-sonnet-4-20250514" : modelName
                ),
                modelIdentifier: modelName.isEmpty ? "claude-sonnet-4-20250514" : modelName,
                temperature: 0.7
            )

        case "gemini":
            guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
                throw ModelRouterError.missingAPIKey("GEMINI_API_KEY")
            }
            return AnyLanguageModelEndpoint(
                languageModel: GeminiLanguageModel(
                    apiKey: apiKey,
                    model: modelName.isEmpty ? "gemini-2.5-pro" : modelName
                ),
                modelIdentifier: modelName.isEmpty ? "gemini-2.5-pro" : modelName,
                temperature: 0.7
            )

        case "ollama":
            return AnyLanguageModelEndpoint(
                languageModel: OllamaLanguageModel(
                    model: modelName.isEmpty ? "qwen2.5" : modelName
                ),
                modelIdentifier: modelName.isEmpty ? "qwen2.5" : modelName,
                temperature: 0.7
            )

        case "system":
            #if canImport(FoundationModels)
                return AnyLanguageModelEndpoint(
                    languageModel: SystemLanguageModel.default,
                    modelIdentifier: modelName.isEmpty ? "default" : modelName,
                    temperature: 0.7
                )
            #else
                throw ModelRouterError.unsupportedProvider(provider)
            #endif

        default:
            throw ModelRouterError.unknownProvider(provider)
        }
    }
}

public enum ModelRouterError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case unsupportedProvider(String)
    case missingAPIKey(String)
    case missingProjectRoot
}
