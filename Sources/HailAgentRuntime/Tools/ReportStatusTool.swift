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
public struct ReportStatusTool: Tool {
    public struct Input: Codable, Sendable {
        public let contextID: AgentContextID
        public let message: String
        public let timestamp: Date?

        enum CodingKeys: String, CodingKey {
            case contextID = "context_id"
            case message
            case timestamp
        }
    }

    public let name = "report_status"
    public let description =
        "Report a short ephemeral status update for the current context (e.g., 'Reading files', 'Running tests')."

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "context_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The agent context ID you are reporting status for.",
                            enumValues: nil
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "A short status message.",
                            enumValues: nil
                        ),
                    ],
                    required: ["context_id", "message"]
                )
            )
        )
    }

    private let sourceAgentID: AgentID
    private let system: ClusterSystem

    public init(sourceAgentID: AgentID, system: ClusterSystem) {
        self.sourceAgentID = sourceAgentID
        self.system = system
    }

    public func effect(for input: Input) throws -> CoordinationEffect {
        CoordinationEffect(subsystem: "agent", action: "report_status")
    }

    public func run(input: Input, token: borrowing EffectToken<CoordinationEffect>) async throws -> String {
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
        try await agent.recordStatusActivity(input.message, at: input.timestamp ?? Date())
        return "Status reported."
    }
}
