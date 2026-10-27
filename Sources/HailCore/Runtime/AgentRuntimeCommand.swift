import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentRuntimeError: Error, Sendable, Equatable, Codable {
    case modelMisbehavior(String)
    /// The model thought for the whole length of an answer without answering.
    case modelThoughtPastAnswer
    /// The model answered, but not in the form asked for, even when told so: `written` is what it
    /// wrote last.
    case modelAnswerOutOfShape(written: String)
    /// The turn made all `limit` tool calls a turn may make, and went on calling.
    case toolCallsRanOut(limit: Int)
    case modelRequestFailed(String)
    case modelUnavailable
    case rateLimit
    case contextLengthExceeded
    case configurationError(String)
    case infrastructureFailure(String)
    case persistenceFailure(String)
    case toolFailed(name: String, reason: String)
    case cancelled
    case sandboxViolation(String)
    /// An event the agent's history can't take: a bug in whoever made it.
    case invalidHistory(AgentHistory.InvalidEvent)
    /// The agent was asked while busy, with what it's busy with: it does one thing at a time, and
    /// whoever asked decides what to do.
    case busy(AgentStatus.Busy)
}

public struct AgentWorkerReference: Sendable {
    public let agentID: AgentID
    public let spawnConfig: AgentSpawnConfig

    public init(agentID: AgentID, spawnConfig: AgentSpawnConfig) {
        self.agentID = agentID
        self.spawnConfig = spawnConfig
    }
}

public enum AgentRunEvent<Output>: Codable, Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
    case runStarted(agentID: AgentID, at: Date)
    /// The input the run answers was received.
    case received(AgentHistory.Input, at: Date)
    /// A cumulative structured snapshot produced while the model is still
    /// generating. Consumers should replace their current preview with this
    /// value; the final typed result arrives separately as
    /// ``responseRecorded(content:at:)``.
    case modelOutputPartialUpdated(content: Output.PartiallyGenerated, at: Date)
    case modelOutputGenerated(content: Output, at: Date)
    case toolRequested(toolCall: ToolCall, at: Date)
    case toolCompleted(result: ToolResult, at: Date)
    /// A status line while the run goes on, such as the model's provider calling a tool, or the
    /// context being compacted.
    case status(GeneratedContent, at: Date)
    /// A piece of the model's reasoning, apart from its reply.
    case reasoning(GeneratedContent, at: Date)
    case responseRecorded(content: Output, at: Date)
    case runCompleted(at: Date)
    case runFailed(error: AgentRuntimeError, at: Date)
}
