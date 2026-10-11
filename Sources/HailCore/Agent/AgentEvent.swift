import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentEvent: Codable, Sendable {
    case activated(agentID: AgentID)
    /// Something happened in the agent's history.
    case history(AgentHistory.Event)
    /// Durable per-request accounting. Providers may report only a subset of
    /// fields; unknown values remain nil in ``ModelUsage``. These events are
    /// intentionally separate from the agent's history so a dashboard
    /// can project usage without replaying model output.
    case modelUsage(ModelUsage, at: Date)
    /// Durable context occupancy for session-owning endpoints.
    case contextUsage(ContextUsage, at: Date)
    /// Durable model request lifecycle. The record is intentionally coarse;
    /// streamed narration remains ephemeral through AgentActivity.
    case modelRequestStarted(ModelRequestRecord)
    case modelRequestCompleted(
        id: ModelRequestID,
        usage: ModelUsage?,
        durationMilliseconds: Int,
        at: Date
    )
    case modelRequestFailed(
        id: ModelRequestID,
        error: AgentRuntimeError,
        durationMilliseconds: Int,
        at: Date
    )
    /// The harness (kimi/claude CLI) session this agent's turns run in,
    /// journaled so a restart can resume it instead of bootstrapping. The
    /// `identity` is the ``AgentSessionIdentity`` fingerprint the session was
    /// created with; a config change invalidates the resume.
    case modelSessionIdentified(id: SessionID, identity: SessionIdentity)
    case deactivated(reason: String)
}

/// A tool call the model made, as the agent's history records it.
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Provider-native generated arguments. Hail does not round-trip a tool
    /// call through a JSON string before authorizing or executing it.
    public let arguments: GeneratedContent

    public init(id: String, name: String, arguments: GeneratedContent) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum ToolFailureKind: String, Codable, Sendable, Equatable {
    /// The model supplied arguments that cannot be decoded or validated.
    case invalidArguments
    /// The request was understood but the operation was refused.
    case rejected
    /// The tool could not currently be reached or configured to run.
    case unavailable
    /// The tool ran into an execution failure that is not otherwise classified.
    case failed
}

public struct ToolResult: Codable, Sendable, Equatable {
    public let toolCallID: String
    public let name: String
    /// What the call did.
    public let output: ToolOutput
    /// The page the call landed on: only its address is kept, never what it showed.
    public let landed: PageAddress?
    public let failureKind: ToolFailureKind?

    public var isError: Bool { failureKind != nil }

    public init(
        toolCallID: String,
        name: String,
        output: ToolOutput,
        landed: PageAddress? = nil,
        failureKind: ToolFailureKind? = nil
    ) {
        self.toolCallID = toolCallID
        self.name = name
        self.output = output
        self.landed = landed
        self.failureKind = failureKind
    }

    enum CodingKeys: String, CodingKey {
        case toolCallID = "tool_call_id"
        case name
        case output
        case landed
        case failureKind = "failure_kind"
    }
}
