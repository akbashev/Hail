import AnyLanguageModel
import HailCore
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Resolves model identifiers to ``ModelEndpoint`` instances.
///
/// Every endpoint is created for one execution turn. Durable conversation state
/// and optional provider session resumption are supplied by Hail; the router
/// does not retain provider endpoints between turns.
public actor ModelRouter {
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let modelEndpointProvider: ModelEndpointProvider?
    private let configuration: ModelRouterConfiguration
    public init(
        configuration: ModelRouterConfiguration,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        modelEndpointProvider: ModelEndpointProvider? = nil
    ) {
        self.configuration = configuration
        self.mcpServerConfiguration = mcpServerConfiguration
        self.modelEndpointProvider = modelEndpointProvider
    }

    /// Returns an endpoint for the given configuration.
    ///
    /// The caller owns the endpoint's execution lifetime. `resumeSession` and
    /// `authority` apply to this turn's endpoint creation.
    public func endpoint(
        for model: String,
        agentID: AgentID,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        return try await makeEndpoint(
            for: model,
            agentID: agentID,
            workspace: workspace,
            executionPolicy: executionPolicy,
            resumeSession: resumeSession,
            authority: authority,
            reasoningEffort: reasoningEffort
        )
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
        agentID: AgentID,
        workspace: AgentWorkspace?,
        executionPolicy: AgentExecutionPolicy,
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws(ModelRouterError) -> any ModelEndpoint {
        let effectiveModel = effectiveModelIdentifier(model)
        guard !effectiveModel.isEmpty else {
            throw ModelRouterError.invalidModel(.empty)
        }
        let model = try Self.parseModel(effectiveModel)
        let reasoning = configuration.selection(
            for: reasoningEffort,
            model: model
        )
        try configuration.validate(reasoning: reasoning, for: model)
        do {
            if let endpoint = try await modelEndpointProvider?(
                ModelEndpointRequest(
                    model: effectiveModel,
                    agentID: agentID,
                    workspace: workspace,
                    executionPolicy: executionPolicy,
                    resumeSession: resumeSession,
                    authority: authority,
                    reasoning: reasoning
                )
            ) {
                return endpoint
            }
        } catch {
            throw ModelRouterError.endpointProviderFailed(model.provider, String(describing: error))
        }
        let provider = model.provider
        let modelName = model.id.rawValue
        let providerContextLabel = agentID.contextID.rawValue

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
                agentID: agentID.rawValue,
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
                agentID: agentID.rawValue,
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
                agentID: agentID.rawValue,
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
                effectiveContextWindow: await configuration.contextWindow(for: model, agentID: agentID),
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
                effectiveContextWindow: await configuration.contextWindow(for: model, agentID: agentID),
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
                effectiveContextWindow: await configuration.contextWindow(for: model, agentID: agentID),
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
                effectiveContextWindow: await configuration.contextWindow(for: model, agentID: agentID),
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
                    for: model,
                    baseURL: baseURL,
                    agentID: agentID
                )
            } catch {
                throw .contextWindowUnavailable(
                    model.provider,
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
            return AnyLanguageModelEndpoint.ollama(
                model: modelName,
                baseURL: baseURL,
                temperature: configuration.temperature,
                contextWindow: numContext,
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
                    effectiveContextWindow: await configuration.contextWindow(for: model, agentID: agentID)
                )
            #else
                throw ModelRouterError.unsupportedProvider(provider.rawValue)
            #endif

        default:
            throw ModelRouterError.unsupportedProvider(provider.rawValue)
        }
    }

    private static func parseModel(_ identifier: String) throws(ModelRouterError) -> AgentModel {
        do {
            return try AgentModel(identifier)
        } catch {
            throw ModelRouterError.invalidModel(error)
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

    public static func generationOptions(
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
        case .openAI, .moonshot, .openAICompatible:
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

    public static func geminiGenerationOptions(
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
