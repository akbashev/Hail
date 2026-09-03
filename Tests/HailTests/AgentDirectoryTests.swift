import Hail
import Testing

@Suite("Agent directory")
struct AgentDirectoryTests {
    private let agentID = AgentID(role: Role("coder"), contextID: .main)

    @Test("an unavailable directory never looks empty or absent")
    func unavailableDirectoryThrows() async throws {
        let runtime = AgentRuntimePlugin(
            defaultModel: try AgentModelReference("test/model"),
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7)
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
}
