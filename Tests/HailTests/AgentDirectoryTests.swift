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

    @Test("spawn configuration stores a workspace id, not a host filesystem path")
    func spawnConfigurationIsPathless() throws {
        let config = AgentSpawnConfig(
            agentID: agentID,
            workspaceID: WorkspaceID("isolated-test-workspace")
        )
        let encoded = try JSONEncoder().encode(config)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("projectRootPath"))
        #expect(!json.contains("path"))
    }

    @Test("omitting workspaceID defaults to a workspace private to the agent's own id")
    func workspaceIDDefaultsToPrivate() {
        let config = AgentSpawnConfig(agentID: agentID)
        #expect(config.workspaceID == WorkspaceID(agentID.rawValue))
    }

    @Test("two different agent ids never default to the same workspace")
    func differentAgentsDefaultToDifferentWorkspaces() {
        let other = AgentID(role: Role("reviewer"), contextID: .main)
        let config = AgentSpawnConfig(agentID: agentID)
        let otherConfig = AgentSpawnConfig(agentID: other)
        #expect(config.workspaceID != otherConfig.workspaceID)
    }

    @Test("an agent's configuration comes from the host's policy over its identity")
    func spawnConfigComesFromHostPolicy() async throws {
        let runtime = try AgentRuntimePlugin(
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            authority: { _ in CompositeAuthority.workspaceDefault(root: "/tmp") },
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") },
            spawnConfigProvider: { agentID in
                AgentSpawnConfig(agentID: agentID, workspaceID: WorkspaceID("project-A"))
            },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("test/model"))
            }
        )
        let config = try await runtime.spawnConfig(for: agentID)
        #expect(config.agentID == agentID)
        #expect(config.workspaceID == WorkspaceID("project-A"))
    }

    @Test("a provider answering for a different agent is rejected")
    func mismatchedSpawnConfigIsRejected() async throws {
        let stranger = AgentID(role: Role("reviewer"), contextID: .main)
        let runtime = try AgentRuntimePlugin(
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            authority: { _ in CompositeAuthority.workspaceDefault(root: "/tmp") },
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") },
            spawnConfigProvider: { _ in AgentSpawnConfig(agentID: stranger) },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("test/model"))
            }
        )
        await #expect(throws: AgentRuntimeError.self) {
            try await runtime.spawnConfig(for: agentID)
        }
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
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            authority: { _ in CompositeAuthority.workspaceDefault(root: "/tmp") },
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("test/model"))
            }
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
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            authority: { _ in CompositeAuthority.workspaceDefault(root: "/tmp") },
            workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("test/model"))
            }
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
                maxToolRounds: 0,
                routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
                authority: { _ in CompositeAuthority.workspaceDefault(root: "/tmp") },
                workspaceProvider: { _ in AgentWorkspace(rootPath: "/tmp") },
                modelSelectionProvider: { _ in
                    ModelConfiguration(model: try AgentModel("test/model"))
                }
            )
        }
    }
}
