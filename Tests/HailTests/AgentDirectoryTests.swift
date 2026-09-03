import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Agent directory")
struct AgentDirectoryTests {
    private let agentID = AgentID(role: Role("coder"), contextID: .main)

    @Test("spawn configuration stores scope, not a host filesystem path")
    func spawnConfigurationIsPathless() throws {
        let config = AgentSpawnConfig(
            agentID: agentID,
            scope: .isolatedWorkspace
        )
        let encoded = try JSONEncoder().encode(config)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("projectRootPath"))
        #expect(!json.contains("path"))
    }

    @Test("an unavailable directory never looks empty or absent")
    func unavailableDirectoryThrows() async throws {
        let runtime = try AgentRuntimePlugin(
            defaultModel: try AgentModelReference("test/model"),
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") }
        )

        await #expect(throws: AgentDirectoryError.unavailable) {
            try await runtime.entry(forAgentID: agentID)
        }
        await #expect(throws: AgentDirectoryError.unavailable) {
            try await runtime.agents(ofType: agentID.role)
        }
        await #expect(throws: AgentDirectoryError.unavailable) {
            try await runtime.allAgents()
        }
        await #expect(throws: AgentDirectoryError.unavailable) {
            try await runtime.unregister(agentID: agentID)
        }
    }

    @Test("runtime rejects an invalid tool-round limit")
    func invalidToolRoundLimitThrows() {
        #expect(throws: AgentRuntimeConfigurationError.invalidMaxToolRounds(0)) {
            try AgentRuntimePlugin(
                defaultModel: try AgentModelReference("test/model"),
                maxToolRounds: 0,
                routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
                workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") }
            )
        }
    }
}
