import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentRuntimeError: Error, Sendable, Equatable, Codable {
    case modelMisbehavior(String)
    case modelUnavailable
    case rateLimit
    case contextLengthExceeded
    case configurationError(String)
    case infrastructureFailure(String)
    case persistenceFailure(String)
    case toolFailed(name: String, reason: String)
    case cancelled
    case sandboxViolation(String)
}

public struct AgentWorkerReference: Sendable {
    public let agentID: AgentID
    public let spawnConfig: AgentSpawnConfig

    public init(agentID: AgentID, spawnConfig: AgentSpawnConfig) {
        self.agentID = agentID
        self.spawnConfig = spawnConfig
    }
}

public enum AgentRunEvent<Output: AgentOutput>: Codable, Sendable {
    case runStarted(agentID: AgentID, at: Date)
    case messageHandled(message: ChatMessage, at: Date)
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

public struct AgentRunSnapshot<Output: AgentOutput>: Codable, Sendable {
    public let events: [AgentRunEvent<Output>]
    public let response: Output?

    public init(events: [AgentRunEvent<Output>], response: Output?) {
        self.events = events
        self.response = response
    }
}

public enum AgentRunChange<Output: AgentOutput>: Codable, Sendable {
    case event(AgentRunEvent<Output>)
    case snapshot(AgentRunSnapshot<Output>)
}

/// The typed turn channel: control, typed partial snapshots, and the typed
/// outcome. Ephemeral narration (status/thinking/text/tool) rides
/// ``AgentActivity`` instead.
public enum AgentUpdate<Output: AgentOutput>: Codable, Sendable {
    case run(AgentRunChange<Output>)
}
