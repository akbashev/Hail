#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentEvent: Codable, Sendable {
    case activated(agentID: AgentID)
    /// The `at` is optional only so journals written before turn timing was
    /// introduced still replay; new events always carry it.
    case turnStarted(at: Date?)
    /// Identifies the current turn without changing the old turnStarted wire
    /// shape, so pre-identification journals remain replayable.
    case turnIdentified(id: TurnID)
    case messageReceived(ChatMessage)
    /// Assistant text accompanying a tool call. Unlike streamed fragments,
    /// this is a single semantic message that must survive context rebuilds
    /// after tool execution and compaction.
    case assistantText(content: String, at: Date)
    case contextSet(contextID: AgentContextID)
    case toolInvoked(ToolCall, at: Date?)
    case toolResult(ToolResult, at: Date?)
    case memoryCommitted(summary: String)
    /// The oldest `archivedCount` thread entries were compacted into
    /// `summary`, which replaces ``AgentState/contextSummary`` (rolling
    /// summary). One atomic event: the summary is a non-deterministic fold
    /// of the archived prefix, so it must be journaled with the boundary —
    /// a snapshot-less replay cannot reproduce it otherwise.
    case conversationCompacted(archivedCount: Int, summary: String)
    case responseReceived(sender: String, payload: Data, at: Date)
    case turnFailed(error: AgentRuntimeError, at: Date)
    case turnCompleted(at: Date?)
    /// Durable per-request accounting. Providers may report only a subset of
    /// fields; unknown values remain nil in ``ModelUsage``. These events are
    /// intentionally separate from the conversation transcript so a dashboard
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

/// A single entry in the agent's conversation thread.
///
/// This is a domain type: it distinguishes text messages, assistant tool-call
/// requests, and tool results. Every text message carries an explicit `sender`
/// so consumers know which actor produced it. The LLM-facing role is derived
/// at the boundary by comparing the sender with the agent being addressed.
public enum ChatMessage: Codable, Sendable, Equatable {
    case text(sender: String, content: String, timestamp: Date)
    case response(sender: String, payload: Data, timestamp: Date)
    case toolCall(calls: [ToolCall], timestamp: Date)
    case toolResult(id: String, content: String, timestamp: Date)
    /// A turn that failed (model error, rate limit, ...). Journaled so the
    /// failure stays visible in the transcript after a reload; prompt
    /// assembly skips it — the model never sees its own turn failures.
    case failure(error: AgentRuntimeError, timestamp: Date)
    /// A human-decision request posted into the thread as a display-only
    /// message (no reasoning turn). Host-agnostic by design: a coordinator
    /// maps its decision values onto these primitives at the boundary. Prompt
    /// assembly skips it — the model learns about resolutions through the
    /// `ask_user` tool result or resume messages, never through these.
    case decisionRequest(id: String, question: String, options: [ChatDecisionOption], timestamp: Date)
    /// The outcome of a ``decisionRequest``, posted when the decision is
    /// resolved. Display-only; skipped by prompt assembly.
    case decisionResolved(id: String, question: String, resolution: String, comment: String?, timestamp: Date)

    /// The moment the entry was journaled.
    public var timestamp: Date {
        switch self {
        case .text(_, _, let timestamp), .response(_, _, let timestamp), .toolCall(_, let timestamp),
            .toolResult(_, _, let timestamp), .failure(_, let timestamp),
            .decisionRequest(_, _, _, let timestamp), .decisionResolved(_, _, _, _, let timestamp):
            return timestamp
        }
    }

    /// Returns a copy of the message with the sender set to the given raw ID.
    /// Non-text messages are returned unchanged.
    public func withSender(_ sender: String) -> ChatMessage {
        switch self {
        case .text(_, let content, let timestamp):
            return .text(sender: sender, content: content, timestamp: timestamp)
        case .response:
            return self
        default:
            return self
        }
    }
}

/// One selectable option of a ``ChatMessage/decisionRequest(id:question:options:timestamp:)``.
public struct ChatDecisionOption: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: ToolArguments

    public init(id: String, name: String, arguments: ToolArguments) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public let toolCallID: String
    public let name: String
    public let output: String
    public let isError: Bool

    enum CodingKeys: String, CodingKey {
        case toolCallID = "tool_call_id"
        case name
        case output
        case isError = "is_error"
    }
}
