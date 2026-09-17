import AnyLanguageModel
import DistributedCluster
import HailCore
import HailModelRuntime
import ScopedEffect
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Allows an agent to report an ephemeral status update for the context it is
/// running in. The status lands on the source agent's own activity feed,
/// resolved through the virtual actors API per call.
@Tool
public struct ReportStatusTool {
    public let name = "report_status"
    public let description =
        "Report a short ephemeral status update for the current context (e.g., 'Reading files', 'Running tests')."

    public var schema: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema.object(
                name: "ReportStatusArguments",
                description: "Arguments for reporting a status update.",
                properties: [
                    .init(
                        name: "context_id",
                        description: "The agent context ID you are reporting status for.",
                        schema: ToolSchema.string(name: "AgentContextID")
                    ),
                    .init(
                        name: "message",
                        description: "A short status message.",
                        schema: ToolSchema.string(name: "StatusMessage")
                    ),
                ]
            )
        )
    }

    private let sourceAgentID: AgentID
    private let system: ClusterSystem

    public init(sourceAgentID: AgentID, system: ClusterSystem) {
        self.sourceAgentID = sourceAgentID
        self.system = system
    }

    public func effect(for input: ReportStatusToolInput) throws -> CoordinationEffect {
        CoordinationEffect(subsystem: "agent", action: "report_status")
    }

    public func runOutput(input: ReportStatusToolInput, token: borrowing EffectToken<CoordinationEffect>) async throws
        -> ToolOutput
    {
        _ = token
        guard
            let entry = try await system.agentRuntime.entry(forAgentID: sourceAgentID),
            let spawnConfig = entry.spawnConfig
        else {
            throw ToolError.notConfigured(
                "No spawn config registered for \(sourceAgentID.rawValue)"
            )
        }
        let agent: Agent = try await system.virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: sourceAgentID.rawValue),
            dependency: spawnConfig
        )
        let timestamp = input.timestamp.flatMap { try? Date.ISO8601FormatStyle().parse($0) } ?? Date()
        try await agent.recordStatusActivity(input.message, at: timestamp)
        return .text("Status reported.")
    }
}

@Generable
public struct ReportStatusToolInput: Sendable {
    public let contextID: String
    public let message: String
    public let timestamp: String?
}
