import HailCore
import HailModelRuntime
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Model routes")
struct ModelRouteTests {
    @Test("a route is a validated provider/model pair")
    func parsesCompleteRoute() throws {
        let route = try AgentModelRoute(identifier: "gemini/gemini-2.5-pro")

        #expect(route.provider == .gemini)
        #expect(route.model == "gemini-2.5-pro")
        #expect(route.identifier == "gemini/gemini-2.5-pro")
    }

    @Test("a model reference rejects incomplete serialized routes")
    func modelReferenceIsStrict() {
        #expect(throws: AgentModelReferenceError.empty) {
            try AgentModelReference("  ")
        }
        #expect(
            throws: AgentModelReferenceError.invalidRoute(.missingModel("gemini"))
        ) {
            try AgentModelReference("gemini")
        }
    }

    @Test("bare providers do not select a hidden model default")
    func rejectsMissingModel() {
        #expect(throws: AgentModelRouteError.missingModel("gemini")) {
            try AgentModelRoute(identifier: "gemini")
        }
        #expect(throws: AgentModelRouteError.missingModel("gemini")) {
            try AgentModelRoute(identifier: "gemini/")
        }
    }

    @Test("custom providers remain valid domain routes")
    func acceptsCustomProvider() throws {
        let route = try AgentModelRoute(identifier: "mystery/model")
        #expect(route.provider == AgentModelProvider.custom("mystery"))
    }

    @Test("the built-in router rejects providers without an endpoint")
    func routerRejectsUnknownProvider() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7),
            projectRootPath: "/tmp"
        )
        await #expect(
            throws: ModelRouterError.invalidRoute(.unknownProvider("mystery"))
        ) {
            try await router.endpoint(
                for: "mystery/model",
                agentID: "coder-main",
                workingDirectory: "/tmp"
            )
        }
    }

    @Test("built-in endpoint constructors reject missing models")
    func endpointRejectsMissingModel() {
        #expect(
            throws: ModelRouterError.invalidRoute(.missingModel("claude"))
        ) {
            try ClaudeCliEndpoint(model: " ", workingDirectory: "/tmp")
        }
        #expect(
            throws: ModelRouterError.invalidRoute(
                .missingModel(AgentModelProvider.kimiCode.rawValue)
            )
        ) {
            try KimiCodeEndpoint(model: "", workingDirectory: "/tmp")
        }
        #expect(
            throws: ModelRouterError.invalidRoute(.missingModel("codex"))
        ) {
            try CodexAppServerEndpoint(model: "", workingDirectory: "/tmp")
        }
    }

    @Test("the router does not invent an application model default")
    func routerRejectsEmptyModel() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7),
            projectRootPath: "/tmp"
        )

        await #expect(
            throws: ModelRouterError.invalidRoute(.missingModel(""))
        ) {
            try await router.endpoint(
                for: " ",
                agentID: "coder-main",
                workingDirectory: "/tmp"
            )
        }
    }

    @Test("provider policy is supplied by the host")
    func providerPolicyIsExplicit() async throws {
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(temperature: 0.7),
            projectRootPath: "/tmp"
        )

        await #expect(throws: ModelRouterError.missingAPIKey(.openAI)) {
            try await router.endpoint(
                for: "openai/gpt-test",
                agentID: "coder-main",
                workingDirectory: "/tmp"
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

    @Test("host-declared model capabilities reject unsupported effort levels")
    func rejectsEffortOutsideConfiguredCapabilities() async throws {
        let model = try AgentModelReference("gemini/gemini-2.5-pro")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(
                        supportedEfforts: [.minimal, .low, .medium, .high]
                    )
                ]
            ),
            projectRootPath: "/tmp"
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
                agentID: "coder-main",
                workingDirectory: "/tmp",
                reasoningEffort: .xhigh
            )
        }
    }

    @Test("host mappings allow Gemini's non-string thinking controls")
    func geminiUsesConfiguredThinkingEncoding() async throws {
        let model = try AgentModelReference("gemini/gemini-2.5-pro")
        let router = ModelRouter(
            configuration: try ModelRouterConfiguration(
                temperature: 0.7,
                apiKeys: [.gemini: "test-key"],
                reasoningCapabilities: [
                    model: ModelReasoningCapabilities(levels: [
                        ModelReasoningLevel(effort: .high, encoding: .dynamic)
                    ])
                ]
            ),
            projectRootPath: "/tmp"
        )

        let endpoint = try await router.endpoint(
            for: model.rawValue,
            agentID: "coder-main",
            workingDirectory: "/tmp",
            reasoningEffort: .high
        )
        #expect(endpoint.model == "gemini-2.5-pro")
    }

    @Test("reasoning capabilities reject invalid token budgets")
    func invalidReasoningTokenBudgetThrows() throws {
        let model = try AgentModelReference("gemini/gemini-2.5-pro")
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

    @Test("reasoning capabilities reject duplicate effort levels")
    func duplicateReasoningEffortThrows() throws {
        let model = try AgentModelReference("gemini/gemini-2.5-pro")
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
