import HailCore
import HailModelRuntime
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private actor ContextWindowStore {
    private var values: [AgentID: Int] = [:]

    func set(_ value: Int, for agentID: AgentID) {
        values[agentID] = value
    }

    func value(for agentID: AgentID) -> Int? {
        return values[agentID]
    }
}

private func agentID(_ rawValue: String) -> AgentID {
    guard let value = AgentID(rawValue: rawValue) else {
        fatalError("Invalid test agent ID: \(rawValue)")
    }
    return value
}

@Suite("Models")
struct ModelRouteTests {
    @Test("a model contains a typed provider and model ID")
    func parsesCompleteModel() throws {
        let model = try AgentModel("gemini/gemini-2.5-pro")

        #expect(model.provider == .gemini)
        #expect(model.id == AgentModelID(rawValue: "gemini-2.5-pro"))
        #expect(model.identifier == "gemini/gemini-2.5-pro")
    }

    @Test("a model rejects incomplete serialized identifiers")
    func modelIsStrict() {
        #expect(throws: AgentModelError.empty) {
            try AgentModel("  ")
        }
        #expect(throws: AgentModelError.missingID("gemini")) {
            try AgentModel("gemini")
        }
    }

    @Test("bare providers do not select a hidden model default")
    func rejectsMissingModel() {
        #expect(throws: AgentModelError.missingID("gemini")) {
            try AgentModel("gemini")
        }
        #expect(throws: AgentModelError.missingID("gemini")) {
            try AgentModel("gemini/")
        }
    }

    @Test("custom providers remain valid model values")
    func acceptsCustomProvider() throws {
        let model = try AgentModel("mystery/model")
        #expect(model.provider == AgentModelProvider.custom("mystery"))
    }

    @Test("the built-in router rejects providers without an endpoint")
    func routerRejectsUnknownProvider() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7)
        )
        await #expect(
            throws: ModelRouterError.unsupportedProvider("mystery")
        ) {
            try await router.endpoint(
                for: "mystery/model",
                agentID: agentID("coder-main"),
                workspace: AgentWorkspace(rootPath: "/tmp")
            )
        }
    }

    @Test("the router does not invent an application model default")
    func routerRejectsEmptyModel() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7)
        )

        await #expect(
            throws: ModelRouterError.invalidModel(.empty)
        ) {
            try await router.endpoint(
                for: " ",
                agentID: agentID("coder-main"),
                workspace: AgentWorkspace(rootPath: "/tmp")
            )
        }
    }

    @Test("provider policy is supplied by the host")
    func providerPolicyIsExplicit() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7)
        )

        await #expect(throws: ModelRouterError.missingAPIKey(.openAI)) {
            try await router.endpoint(
                for: "openai/gpt-test",
                agentID: agentID("coder-main"),
                workspace: AgentWorkspace(rootPath: "/tmp")
            )
        }
    }

    @Test("invalid host router policy is rejected at construction")
    func invalidProviderPolicyThrows() {
        #expect(
            throws: ModelRouterConfigurationError.invalidTemperature(-0.1)
        ) {
            try ModelRouterConfiguration(temperature: -0.1)
        }
        #expect(
            throws: ModelRouterConfigurationError.invalidBaseURL(
                .ollama,
                "file:///tmp"
            )
        ) {
            try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(fileURLWithPath: "/tmp")]
            )
        }
    }

    @Test("model-specific context windows override provider defaults")
    func modelContextWindowOverridesProviderWindow() async throws {
        let model = try AgentModel("ollama/qwen3.5:9b-mlx")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
                contextWindows: [.ollama: 4_096],
                modelContextWindows: [model: 131_072]
            )
        )

        let endpoint = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("coder-main"),
            workspace: AgentWorkspace(rootPath: "/tmp")
        )

        #expect(endpoint.effectiveContextWindow == 131_072)
    }

    @Test("agent context windows are resolved per turn for shared models")
    func agentContextWindowChangesApplyToTheNextTurn() async throws {
        let model = try AgentModel("ollama/qwen3.5:9b-mlx")
        let windows = ContextWindowStore()
        await windows.set(8_192, for: agentID("profile-a"))
        await windows.set(32_768, for: agentID("profile-b"))

        let resolver = ModelContextWindowResolver(
            configured: { _, agentID in
                await windows.value(for: agentID)
            }
        )
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
                contextWindowResolver: resolver
            )
        )

        let firstA = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("profile-a"),
            workspace: AgentWorkspace(rootPath: "/tmp")
        )
        let firstB = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("profile-b"),
            workspace: AgentWorkspace(rootPath: "/tmp")
        )
        #expect(firstA.effectiveContextWindow == 8_192)
        #expect(firstB.effectiveContextWindow == 32_768)

        await windows.set(65_536, for: agentID("profile-a"))
        let secondA = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("profile-a"),
            workspace: AgentWorkspace(rootPath: "/tmp")
        )
        #expect(secondA.effectiveContextWindow == 65_536)
    }

    @Test("invalid model context windows are rejected at construction")
    func invalidModelContextWindowThrows() throws {
        let model = try AgentModel("ollama/qwen3.5:9b-mlx")
        #expect(
            throws: ModelRouterConfigurationError.invalidModelContextWindow(model, 0)
        ) {
            try ModelRouterConfiguration(
                temperature: 0.7,
                modelContextWindows: [model: 0]
            )
        }
    }

    @Test("host-declared model capabilities reject unsupported effort levels")
    func rejectsEffortOutsideConfiguredCapabilities() async throws {
        let model = try AgentModel("gemini/gemini-2.5-pro")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(
                        supportedEfforts: [.minimal, .low, .medium, .high]
                    )
                ]
            )
        )

        await #expect(
            throws: ModelRouterError.unsupportedReasoningEffort(
                provider: .gemini,
                model: "gemini-2.5-pro",
                effort: .xhigh
            )
        ) {
            try await router.endpoint(
                for: model.rawValue,
                agentID: agentID("coder-main"),
                workspace: AgentWorkspace(rootPath: "/tmp"),
                reasoningEffort: .xhigh
            )
        }
    }

    @Test("host mappings allow Gemini's non-string thinking controls")
    func geminiUsesConfiguredThinkingEncoding() async throws {
        let model = try AgentModel("gemini/gemini-2.5-pro")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                apiKeys: [.gemini: "test-key"],
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(levels: [
                        ModelReasoningLevel(effort: .high, encoding: .dynamic)
                    ])
                ]
            )
        )

        let endpoint = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("coder-main"),
            workspace: AgentWorkspace(rootPath: "/tmp"),
            reasoningEffort: .high
        )
        #expect(endpoint.model == "gemini-2.5-pro")
    }

    @Test("reasoning capabilities reject invalid token budgets")
    func invalidReasoningTokenBudgetThrows() throws {
        let model = try AgentModel("gemini/gemini-2.5-pro")
        #expect(throws: ModelRouterConfigurationError.invalidReasoningTokenBudget(model, 0)) {
            try ModelRouterConfiguration(
                temperature: 0.7,
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(
                        levels: [
                            ModelReasoningLevel(
                                effort: .high,
                                encoding: .tokenBudget(0)
                            )
                        ]
                    )
                ]
            )
        }
    }

    @Test("Ollama maps the declared no-reasoning level to its think switch")
    func ollamaAcceptsDeclaredNoReasoningLevel() async throws {
        let model = try AgentModel("ollama/qwen3:8b")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(levels: [
                        ModelReasoningLevel(effort: .none, encoding: .disabled)
                    ])
                ]
            )
        )

        let endpoint = try await router.endpoint(
            for: model.rawValue,
            agentID: agentID("memory-extractor"),
            workspace: AgentWorkspace(rootPath: "/tmp"),
            reasoningEffort: ReasoningEffort.none
        )
        #expect(endpoint is AnyLanguageModelEndpoint)
    }

    @Test("Ollama rejects graded effort instead of approximating it")
    func ollamaRejectsGradedEffort() async throws {
        let model = try AgentModel("ollama/qwen3:8b")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                baseURLs: [.ollama: URL(string: "http://localhost:11434")!]
            )
        )

        await #expect(
            throws: ModelRouterError.unsupportedReasoningEffort(
                provider: .ollama,
                model: "qwen3:8b",
                effort: .high
            )
        ) {
            try await router.endpoint(
                for: model.rawValue,
                agentID: agentID("coder-main"),
                workspace: AgentWorkspace(rootPath: "/tmp"),
                reasoningEffort: .high
            )
        }
    }

    @Test("reasoning capabilities reject duplicate effort levels")
    func duplicateReasoningEffortThrows() throws {
        let model = try AgentModel("gemini/gemini-2.5-pro")
        #expect(throws: ModelRouterConfigurationError.duplicateReasoningEffort(model, .high)) {
            try ModelRouterConfiguration(
                temperature: 0.7,
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(
                        levels: [
                            ModelReasoningLevel(effort: .high, encoding: .dynamic),
                            ModelReasoningLevel(effort: .high, encoding: .tokenBudget(1)),
                        ]
                    )
                ]
            )
        }
    }
}
