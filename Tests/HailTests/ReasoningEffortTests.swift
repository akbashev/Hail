import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    @Test("effort identifiers retain their provider-facing names")
    func builtInEffortNames() {
        #expect(ReasoningEffort.xhigh.rawValue == "xhigh")
    }

    @Test("effort values are extensible and round-trip through Codable")
    func customEffortRoundTrips() throws {
        let effort = try ReasoningEffort.custom("provider-special")
        let data = try JSONEncoder().encode(effort)
        let decoded = try JSONDecoder().decode(ReasoningEffort.self, from: data)

        #expect(decoded == effort)
    }

    @Test("empty effort values are rejected")
    func emptyEffortThrows() {
        #expect(throws: ReasoningEffortError.empty) {
            try ReasoningEffort("  ")
        }
    }

    @Test("model capabilities are an explicit host-owned set")
    func capabilitiesRemainOpenEnded() throws {
        let custom = try ReasoningEffort.custom("provider-special")
        let capabilities = ModelReasoningCapabilities(
            supportedEfforts: [.low, .medium, .high, custom]
        )

        #expect(capabilities.supports(.low))
        #expect(capabilities.supports(custom))
        #expect(!capabilities.supports(.xhigh))
    }

    @Test("behavior persists the host-selected effort")
    func behaviorRoundTripsEffort() throws {
        let definition = AgentDefinition(
            role: Role("coder"),
            behavior: .init(
                systemPrompt: "Code.",
                model: try AgentModel("codex/gpt-5.6-luna"),
                reasoningEffort: .xhigh
            ),
        )

        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(AgentDefinition.self, from: data)

        #expect(decoded.behavior.reasoningEffort == .xhigh)
    }

    @Test("model catalogs use typed provider and model identifiers")
    func modelCatalogUsesDomainIDs() throws {
        let catalog = ModelCatalog(suggestions: [
            .kimiCode: ["k3"],
            .custom("host-provider"): ["host-model"],
        ])

        #expect(catalog.suggestions(for: .kimiCode).map(\.rawValue) == ["k3"])
        #expect(catalog.modelNames(for: .custom("host-provider")) == ["host-model"])

        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: data)
        #expect(decoded == catalog)
    }
}
