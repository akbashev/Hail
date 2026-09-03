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
}
