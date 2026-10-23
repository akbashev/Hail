import ScopedEffect

/// The complete model configuration selected for one agent turn.
public struct ModelConfiguration: Sendable, Hashable {
    public let model: AgentModel
    public let reasoningEffort: ReasoningEffort?

    public init(
        model: AgentModel,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

/// The application context needed to select the model configuration for one
/// turn. Selection is performed again for every turn.
public struct ModelSelectionRequest: Sendable {
    public let agentID: AgentID

    public init(
        agentID: AgentID
    ) {
        self.agentID = agentID
    }
}

/// Host hook for selecting the complete model configuration used by the next
/// turn. A missing or unavailable configuration is an error, not a reason to
/// reuse an older model.
public typealias ModelSelectionProvider =
    @Sendable (ModelSelectionRequest) async throws -> ModelConfiguration

/// Everything a host needs to construct an endpoint that Hail does not own.
/// Returning `nil` delegates to Hail's built-in provider routing.
public struct ModelEndpointRequest: Sendable {
    public let model: String
    /// The optional host-selected effort and its wire representation.
    public let reasoning: ReasoningEffortSelection?
    public let agentID: AgentID
    /// Resolved workspace context for host/process-backed endpoints. HTTP
    /// model endpoints can ignore it.
    public let workspace: AgentWorkspace?
    public let executionPolicy: AgentExecutionPolicy
    public let authority: (any Authority)?

    public init(
        model: String,
        agentID: AgentID,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy,
        authority: (any Authority)?,
        reasoning: ReasoningEffortSelection? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.agentID = agentID
        self.workspace = workspace
        self.executionPolicy = executionPolicy
        self.authority = authority
    }
}

/// Host-owned extension point for model providers not built into Hail.
public typealias ModelEndpointProvider =
    @Sendable (ModelEndpointRequest) async throws -> (any ModelEndpoint)?
