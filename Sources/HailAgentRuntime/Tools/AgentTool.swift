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

public struct AgentTool: Tool {
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

    public struct Input: Codable, Sendable {
        public let action: Action
        public let target: MessageTarget?
        public let message: String?
    }

    public let name = "agent"
    public let description =
        "Discover and communicate with other agents. Use list_agents to find active agents, then send a message to one by its agent id. "
        + "Messages are delivered asynchronously: the recipient processes them in its own time and responds with a message of its own — do not expect a synchronous reply."

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "action": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The action to perform: 'send' or 'list_agents'",
                            enumValues: ["send", "list_agents"]
                        ),
                        "target": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "For 'send': the recipient's full agent id (e.g. 'supervisor-main', 'coder-chat', 'coder-T-42'). Use list_agents to discover active agents and their ids.",
                            enumValues: nil
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "The message to send. Required for 'send'.",
                            enumValues: nil
                        ),
                    ],
                    required: ["action"]
                )
            )
        )
    }

    private let sourceAgentID: AgentID
    private let system: ClusterSystem
    private let projectRootPath: String
    private let scope: AgentScope
    private let agentDirectoryID: AgentDirectoryID

    public init(
        sourceAgentID: AgentID,
        system: ClusterSystem,
        projectRootPath: String,
        scope: AgentScope,
        agentDirectoryID: AgentDirectoryID
    ) {
        self.sourceAgentID = sourceAgentID
        self.system = system
        self.projectRootPath = projectRootPath
        self.scope = scope
        self.agentDirectoryID = agentDirectoryID
    }

    public func effect(for input: Input) throws -> CoordinationEffect {
        CoordinationEffect(subsystem: "agent", action: input.action.rawValue)
    }

    public func execute(input: Input, token: borrowing EffectToken<CoordinationEffect>) async throws -> String {
        _ = token
        switch input.action {
        case .listAgents:
            let agents = await system.agentRuntime.allAgents()
            guard !agents.isEmpty else {
                return "No active agents."
            }
            var lines = ["Active agents:"]
            for entry in agents {
                lines.append("- \(entry.agentID) (type: \(entry.role))")
            }
            return lines.joined(separator: "\n")

        case .send:
            guard let target = input.target, !target.rawValue.isEmpty else {
                throw ToolError.missingArgument("target")
            }
            guard let messageText = input.message, !messageText.isEmpty else {
                throw ToolError.missingArgument("message")
            }

            // Targets are concrete agent ids (e.g. `supervisor-main`,
            // `coder-chat`, `coder-T-42`) — discoverable via `list_agents`.
            // No bare-role resolution: an agent is addressed by the one id
            // it was spawned with, and unknown ids fail loudly instead of
            // spawning phantom agents.
            guard let targetID = AgentID(rawValue: target.rawValue) else {
                throw AgentRuntimeError.modelMisbehavior(
                    "Unknown agent id '\(target.rawValue)'. Use list_agents to discover active agent ids."
                )
            }
            // `AgentID(rawValue:)` accepts any hyphenated string, and
            // `getActor` below CREATES the actor when absent — so parsing
            // alone cannot reject a hallucinated or mistyped id (e.g.
            // `coder-T-999`), which would silently activate a brand-new
            // agent under this sender's root/scope. The directory is the
            // existence check: agents register on activation and unregister
            // on deactivation, so an unlisted id is unknown. Consequence:
            // sending to a passivated agent now fails loudly instead of
            // reactivating it — the tool's contract is `list_agents` first,
            // and that only ever shows active agents. A small TOCTOU window
            // remains: a target that deactivates between this check and
            // `getActor` is re-spawned below, which is legitimate (the id
            // was real moments ago).
            guard await system.agentRuntime.entry(forAgentID: targetID) != nil else {
                throw AgentRuntimeError.modelMisbehavior(
                    "Unknown agent id '\(target.rawValue)'. Use list_agents to discover active agent ids."
                )
            }
            let other: Agent = try await system.virtualActors.getActor(
                identifiedBy: VirtualActorID(rawValue: targetID.rawValue),
                dependency: AgentSpawnConfig(
                    agentID: targetID,
                    projectRootPath: projectRootPath,
                    scope: scope,
                    agentDirectoryID: agentDirectoryID
                )
            )
            // Tag the real sender and deliver asynchronously: the caller
            // structures the concurrency (here: detached), so a slow turn
            // can never lose the message and a timeout on our side can
            // never lose the response. The reply arrives as a message.
            Task {
                let _: String? = try? await other.respond(
                    ChatMessage.text(
                        sender: sourceAgentID.rawValue,
                        content: messageText,
                        timestamp: Date()
                    )
                )
            }
            return "Delivered to \(targetID.rawValue). They will respond when done."
        }
    }
}
