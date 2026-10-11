import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentRuntimeError: Error, Sendable, Equatable, Codable {
    case modelMisbehavior(String)
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
    case responseRecorded(content: Output, at: Date)
    case runCompleted(at: Date)
    case runFailed(error: AgentRuntimeError, at: Date)
}
