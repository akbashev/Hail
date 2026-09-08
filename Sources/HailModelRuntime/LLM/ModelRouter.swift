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
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let modelEndpointProvider: ModelEndpointProvider?
    private let configuration: ModelRouterConfiguration
    private var cache: [CacheKey: any ModelEndpoint] = [:]

    private struct CacheKey: Hashable, Sendable {
        let model: String
        let reasoningEffort: ReasoningEffort?
        let agentID: String
        let contextID: AgentContextID?
        let workspace: AgentWorkspace?
        let executionPolicy: AgentExecutionPolicy
    }

    public init(
        configuration: ModelRouterConfiguration,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        modelEndpointProvider: ModelEndpointProvider? = nil
    ) {
        self.configuration = configuration
        self.mcpServerConfiguration = mcpServerConfiguration
        self.modelEndpointProvider = modelEndpointProvider
    }

    /// Returns the cached ``ModelEndpoint`` for the given configuration,
    /// creating and caching it if necessary.
    ///
    /// The caller owns the streaming effect; this router only resolves and
    /// caches the endpoint instance. `resumeSession` and `authority` are used
    /// only when a new endpoint is created — a cached endpoint already owns
    /// its live session and authority. The creation authority scopes only
    /// endpoint infrastructure (the harness spawn); a turn's lane authority
    /// flows per-stream through ``SessionOwningEndpoint`` instead, which is
    /// why ``CacheKey`` has no authority component (see the lane-authority
    /// invariant in `Agent.reasoningLoop`).
    public func endpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        try await cachedEndpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority,
            reasoningEffort: reasoningEffort
        )
    }

    private func cachedEndpoint(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        let key = CacheKey(
            model: model,
            reasoningEffort: reasoningEffort,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
            executionPolicy: executionPolicy
        )

        if let cached = cache[key] {
            return cached
        }

        let endpoint = try await makeEndpoint(
            for: model,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority,
            reasoningEffort: reasoningEffort
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
    /// ``endpoint(for:agentID:contextID:workspace:executionPolicy:resumeSession:authority:)``
    /// call rebuilds the endpoint cold, resuming from the journaled session.
    public func evict(
        for model: String,
        agentID: String,
        contextID: AgentContextID? = nil,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        reasoningEffort: ReasoningEffort? = nil
    ) async {
        let key = CacheKey(
            model: model,
            reasoningEffort: reasoningEffort,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
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
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        reasoningEffort: ReasoningEffort? = nil
    ) throws(ModelRouterError) {
        let key = CacheKey(
            model: model,
            reasoningEffort: reasoningEffort,
            agentID: agentID,
            contextID: contextID,
            workspace: workspace,
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
    /// The router only normalizes surrounding whitespace. Model defaults are
    /// application configuration and must be resolved before this boundary.
    private func effectiveModelIdentifier(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeEndpoint(
        for model: String,
        agentID: String?,
        contextID: AgentContextID?,
        workspace: AgentWorkspace?,
        executionPolicy: AgentExecutionPolicy,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        let effectiveModel = effectiveModelIdentifier(model)
        guard !effectiveModel.isEmpty else {
            throw ModelRouterError.invalidRoute(.missingModel(""))
        }
        let route = try Self.parseRoute(effectiveModel)
        let reasoning = configuration.selection(
            for: reasoningEffort,
            route: route
        )
        try configuration.validate(reasoning: reasoning, for: route)
        if let endpoint = modelEndpointProvider?(
            ModelEndpointRequest(
                model: effectiveModel,
                agentID: agentID,
                contextID: contextID,
                workspace: workspace,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority,
                reasoning: reasoning
            )
        ) {
            return endpoint
        }
        let provider = route.provider
        let modelName = route.model
        let providerContextLabel = contextID?.rawValue

        switch provider {
        case .codex:
            let workingDirectory = try Self.requireWorkingDirectory(workspace)
            try Self.requireRawReasoningEncoding(
                reasoning,
                provider: provider,
                model: modelName
            )
            return try CodexAppServerEndpoint(
                model: modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority,
                reasoningEffort: reasoning?.effort
            )

        case .kimiCode:
            let workingDirectory = try Self.requireWorkingDirectory(workspace)
            try Self.requireRawReasoningEncoding(
                reasoning,
                provider: provider,
                model: modelName
            )
            return try KimiCodeEndpoint(
                model: modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority,
                reasoningEffort: reasoning?.effort
            )

        case .claude:
            let workingDirectory = try Self.requireWorkingDirectory(workspace)
            try Self.requireRawReasoningEncoding(
                reasoning,
                provider: provider,
                model: modelName
            )
            return try ClaudeCliEndpoint(
                model: modelName,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: providerContextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                executionPolicy: executionPolicy,
                resumeSession: resumeSession,
                authority: authority,
                reasoningEffort: reasoning?.effort
            )

        case .moonshot:
            let apiKey = try configuration.apiKey(for: .moonshot)
            let baseURL = try configuration.baseURL(for: .moonshot)
            return AnyLanguageModelEndpoint(
                languageModel: OpenAILanguageModel(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    model: modelName
                ),
                modelIdentifier: modelName,
                temperature: configuration.temperature,
                effectiveContextWindow: configuration.configuredContextWindow(for: route),
                generationOptions: try Self.generationOptions(
                    provider: provider,
                    model: modelName,
                    temperature: configuration.temperature,
                    reasoning: reasoning
                )
            )

        case .openAI:
            let apiKey = try configuration.apiKey(for: .openAI)
            return AnyLanguageModelEndpoint(
                languageModel: OpenAILanguageModel(
                    apiKey: apiKey,
                    model: modelName
                ),
                modelIdentifier: modelName,
                temperature: configuration.temperature,
                effectiveContextWindow: configuration.configuredContextWindow(for: route),
                generationOptions: try Self.generationOptions(
                    provider: provider,
                    model: modelName,
                    temperature: configuration.temperature,
                    reasoning: reasoning
                )
            )

        case .anthropic:
            let apiKey = try configuration.apiKey(for: .anthropic)
            return AnyLanguageModelEndpoint(
                languageModel: AnthropicLanguageModel(
                    apiKey: apiKey,
                    model: modelName
                ),
                modelIdentifier: modelName,
                temperature: configuration.temperature,
                effectiveContextWindow: configuration.configuredContextWindow(for: route),
                generationOptions: try Self.generationOptions(
                    provider: provider,
                    model: modelName,
                    temperature: configuration.temperature,
                    reasoning: reasoning
                )
            )

        case .gemini:
            let apiKey = try configuration.apiKey(for: .gemini)
            return AnyLanguageModelEndpoint(
                languageModel: GeminiLanguageModel(
                    apiKey: apiKey,
                    model: modelName
                ),
                modelIdentifier: modelName,
                temperature: configuration.temperature,
                effectiveContextWindow: configuration.configuredContextWindow(for: route),
                generationOptions: try Self.geminiGenerationOptions(
                    model: modelName,
                    temperature: configuration.temperature,
                    reasoning: reasoning
                )
            )

        case .ollama:
            let baseURL = try configuration.baseURL(for: .ollama)
            let numContext: Int?
            do {
                numContext = try await configuration.contextWindowResolver.resolve(
                    for: route,
                    baseURL: baseURL
                )
            } catch {
                throw .contextWindowUnavailable(
                    route.provider,
                    modelName,
                    String(describing: error)
                )
            }
            // Ollama's control surface is the boolean `think` switch. Only an
            // explicit "no reasoning" selection maps onto it; graded effort
            // levels stay unsupported rather than being silently approximated.
            let think: Bool?
            switch reasoning?.encoding {
            case .none:
                think = nil
            case .disabled:
                think = false
            case .raw, .dynamic, .tokenBudget:
                throw ModelRouterError.unsupportedReasoningEffort(
                    provider: provider,
                    model: modelName,
                    effort: reasoning?.effort ?? .none
                )
            }
            return OllamaEndpoint(
                model: modelName,
                baseURL: baseURL,
                temperature: configuration.temperature,
                numContext: numContext,
                think: think
            )

        case .system:
            #if canImport(FoundationModels)
                try Self.rejectReasoningEffort(
                    reasoning,
                    provider: provider,
                    model: modelName
                )
                return AnyLanguageModelEndpoint(
                    languageModel: SystemLanguageModel.default,
                    modelIdentifier: modelName,
                    temperature: configuration.temperature,
                    effectiveContextWindow: configuration.configuredContextWindow(for: route)
                )
            #else
                throw ModelRouterError.unsupportedProvider(provider.rawValue)
            #endif

        default:
            throw ModelRouterError.invalidRoute(.unknownProvider(provider.rawValue))
        }
    }

    private static func parseRoute(_ identifier: String) throws(ModelRouterError) -> AgentModelRoute {
        do {
            return try AgentModelRoute(identifier: identifier)
        } catch {
            throw ModelRouterError.invalidRoute(error)
        }
    }

    private static func requireWorkingDirectory(
        _ workspace: AgentWorkspace?
    ) throws(ModelRouterError) -> String {
        guard let workspace,
            !workspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw .missingWorkingDirectory
        }
        return workspace.rootPath
    }

    private static func generationOptions(
        provider: AgentModelProvider,
        model: String,
        temperature: Double,
        reasoning: ReasoningEffortSelection?
    ) throws(ModelRouterError) -> GenerationOptions {
        var options = GenerationOptions(temperature: temperature)
        guard let reasoning else { return options }

        guard reasoning.encoding == .raw else {
            throw ModelRouterError.unsupportedReasoningEffort(
                provider: provider,
                model: model,
                effort: reasoning.effort
            )
        }

        switch provider {
        case .openAI, .moonshot:
            // OpenAI-compatible chat endpoints use the vendor's raw effort
            // value. Keeping this in `extraBody` preserves newer values such
            // as `xhigh` and `max` even when the client package's typed enum
            // has not caught up yet.
            options[custom: OpenAILanguageModel.self] = .init(
                extraBody: ["reasoning_effort": .string(reasoning.effort.rawValue)]
            )
        case .anthropic:
            options[custom: AnthropicLanguageModel.self] = .init(
                extraBody: [
                    "output_config": .object([
                        "effort": .string(reasoning.effort.rawValue)
                    ])
                ]
            )
        default:
            throw ModelRouterError.unsupportedReasoningEffort(
                provider: provider,
                model: model,
                effort: reasoning.effort
            )
        }
        return options
    }

    private static func geminiGenerationOptions(
        model: String,
        temperature: Double,
        reasoning: ReasoningEffortSelection?
    ) throws(ModelRouterError) -> GenerationOptions {
        var options = GenerationOptions(temperature: temperature)
        guard let reasoning else { return options }

        let thinking: GeminiLanguageModel.CustomGenerationOptions.Thinking
        switch reasoning.encoding {
        case .disabled:
            thinking = .disabled
        case .dynamic:
            thinking = .dynamic
        case .tokenBudget(let budget) where budget > 0:
            thinking = .budget(budget)
        case .raw, .tokenBudget(_):
            throw .unsupportedReasoningEffort(
                provider: .gemini,
                model: model,
                effort: reasoning.effort
            )
        }
        options[custom: GeminiLanguageModel.self] = .init(thinking: thinking)
        return options
    }

    private static func requireRawReasoningEncoding(
        _ reasoning: ReasoningEffortSelection?,
        provider: AgentModelProvider,
        model: String
    ) throws(ModelRouterError) {
        guard let reasoning else { return }
        guard reasoning.encoding != .raw else { return }
        throw .unsupportedReasoningEffort(
            provider: provider,
            model: model,
            effort: reasoning.effort
        )
    }

    private static func rejectReasoningEffort(
        _ reasoning: ReasoningEffortSelection?,
        provider: AgentModelProvider,
        model: String
    ) throws(ModelRouterError) {
        guard let reasoning else { return }
        throw .unsupportedReasoningEffort(
            provider: provider,
            model: model,
            effort: reasoning.effort
        )
    }

}
