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

@Tool
public struct AgentTool {
    @Generable
    public enum Action: String, Codable, Sendable {
        case send
        case listAgents = "list_agents"
    }

    public struct MessageTarget: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    @Generable
    public struct Input: Sendable {
        public let action: Action
        /// Agent IDs are opaque model-provided identifiers. Keep them as a
        /// string in generated content and validate them at the effect
        /// boundary instead of exposing a wrapper-shaped object to the model.
        public let target: String?
        public let message: String?
    }

    public let name = "agent"
    public let description =
        "Discover and communicate with other agents. Use list_agents to find currently active agents, or send to a previously known agent id. "
        + "Messages are queued asynchronously on a best-effort basis: the recipient processes them in its own time and responds with a message of its own — do not expect a synchronous reply or delivery across a process restart. "
        + "The current agent is not a valid recipient; continue the task in this turn instead of sending a message to yourself."

    public var schema: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema.object(
                name: "AgentArguments",
                description: "Arguments for communicating with another agent.",
                properties: [
                    .init(
                        name: "action",
                        description: "The action to perform: send or list_agents.",
                        schema: ToolSchema.string(
                            name: "AgentAction",
                            choices: ["send", "list_agents"]
                        )
                    ),
                    .init(
                        name: "target",
                        description: "For send: the recipient's full agent id.",
                        schema: ToolSchema.string(name: "AgentTarget"),
                        isOptional: true
                    ),
                    .init(
                        name: "message",
                        description: "The message to send. Required for send.",
                        schema: ToolSchema.string(name: "AgentMessage"),
                        isOptional: true
                    ),
                ]
            )
        )
    }

    private let sourceAgentID: AgentID
    private let system: ClusterSystem
    private let scope: AgentScope
    private let agentDirectoryID: AgentDirectoryID

    public init(
        sourceAgentID: AgentID,
        system: ClusterSystem,
        scope: AgentScope,
        agentDirectoryID: AgentDirectoryID
    ) {
        self.sourceAgentID = sourceAgentID
        self.system = system
        self.scope = scope
        self.agentDirectoryID = agentDirectoryID
    }

    public func effect(for input: Input) throws -> CoordinationEffect {
        CoordinationEffect(subsystem: "agent", action: input.action.rawValue)
    }

    public func runOutput(input: Input, token: borrowing EffectToken<CoordinationEffect>) async throws -> ToolOutput {
        _ = token
        switch input.action {
        case .listAgents:
            let agents = try await system.agentRuntime.allAgents()
                .filter { $0.agentID != sourceAgentID }
            guard !agents.isEmpty else {
                return .text("No other active agents.")
            }
            var lines = ["Active agents:"]
            for entry in agents {
                lines.append("- \(entry.agentID) (type: \(entry.role))")
            }
            return .text(lines.joined(separator: "\n"))

        case .send:
            guard let target = input.target, !target.isEmpty else {
                throw ToolError.missingArgument("target")
            }
            guard let messageText = input.message, !messageText.isEmpty else {
                throw ToolError.missingArgument("message")
            }

            // Targets are concrete agent ids (e.g. `supervisor-main`,
            // `coder-chat`, `coder-T-42`). No bare-role resolution: an agent
            // is addressed by its stable virtual-actor id. The virtual-actor
            // runtime may reactivate a passivated agent, just like Orleans or
            // Akka Cluster Sharding; the active directory is only a discovery
            // projection and is not consulted for correctness.
            guard let targetID = AgentID(rawValue: target) else {
                throw AgentRuntimeError.modelMisbehavior(
                    "Invalid agent id '\(target)'. Use a full agent id such as 'coder-T-42'."
                )
            }
            guard targetID != sourceAgentID else {
                throw AgentRuntimeError.modelMisbehavior(
                    "An agent cannot send a message to itself. Continue the task in this turn."
                )
            }
            let other: Agent = try await system.virtualActors.getActor(
                identifiedBy: VirtualActorID(rawValue: targetID.rawValue),
                dependency: AgentSpawnConfig(
                    agentID: targetID,
                    scope: scope,
                    agentDirectoryID: agentDirectoryID
                )
            )
            // Tag the real sender and queue asynchronously. The runtime owns
            // the task so it remains observable until completion, while the
            // tool still returns without waiting for the recipient. This is
            // intentionally best effort: a process restart can lose it.
            let logger = system.log
            let deliveryID = await system.agentRuntime.enqueueDelivery {
                do {
                    let message = ChatMessage.text(
                        sender: sourceAgentID.rawValue,
                        content: messageText,
                        timestamp: Date()
                    )
                    let _: String = try await other.respond(
                        message,
                        message: message
                    )
                } catch {
                    logger.error(
                        "Asynchronous agent delivery failed",
                        metadata: [
                            "sourceAgentID": .string(sourceAgentID.rawValue),
                            "targetAgentID": .string(targetID.rawValue),
                            "error": .string(String(describing: error)),
                        ]
                    )
                    throw error
                }
            }
            return .text(
                "Queued message to \(targetID.rawValue) (delivery \(deliveryID)); best effort, no response is expected in this turn."
            )
        }
    }
}
