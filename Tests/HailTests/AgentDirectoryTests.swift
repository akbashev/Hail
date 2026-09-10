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

    @Test("snapshot policy is part of the spawn dependency")
    func spawnConfigurationCarriesSnapshotPolicy() throws {
        let policy = AgentSnapshotPolicy.periodic(
            every: 123,
            retention: .keepLast(4)
        )
        let config = AgentSpawnConfig(
            agentID: agentID,
            snapshotPolicy: policy
        )

        let roundTripped = try JSONDecoder().decode(
            AgentSpawnConfig.self,
            from: JSONEncoder().encode(config)
        )

        #expect(roundTripped.snapshotPolicy == policy)
    }

    @Test("default snapshot policy translates into executable snapshotting")
    func defaultSnapshotPolicyIsTranslated() async throws {
        let runtime = try AgentRuntimePlugin(
            defaultModel: try AgentModel("test/model"),
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") }
        )
        let config = AgentSpawnConfig(agentID: agentID)

        let snapshotting = await runtime.snapshotting(for: config)
        guard case .every(let numberOfEvents, let retention, let orWhen) = snapshotting else {
            Issue.record("Expected periodic snapshotting")
            return
        }
        #expect(numberOfEvents == 250)
        #expect(orWhen != nil)
        if case .keepLast(let count) = retention {
            #expect(count == 2)
        } else {
            Issue.record("Expected keep-last retention")
        }
    }

    @Test("an unavailable directory never looks empty or absent")
    func unavailableDirectoryThrows() async throws {
        let runtime = try AgentRuntimePlugin(
            defaultModel: try AgentModel("test/model"),
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
                defaultModel: try AgentModel("test/model"),
                maxToolRounds: 0,
                routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
                workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") }
            )
        }
    }
}
