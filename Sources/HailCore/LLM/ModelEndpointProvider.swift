import ScopedEffect

/// Everything a host needs to construct an endpoint that Hail does not own.
/// Returning `nil` delegates to Hail's built-in provider routing.
public struct ModelEndpointRequest: Sendable {
    public let model: String
    /// The optional host-selected effort and its wire representation.
    public let reasoning: ReasoningEffortSelection?
    public let agentID: String?
    public let contextID: AgentContextID?
    /// Resolved workspace context for host/process-backed endpoints. HTTP
    /// model endpoints can ignore it.
    public let workspace: AgentWorkspace?
    public let executionPolicy: AgentExecutionPolicy
    public let resumeSession: ModelSessionResume?
    public let authority: (any Authority)?

    public init(
        model: String,
        agentID: String?,
        contextID: AgentContextID?,
        workspace: AgentWorkspace? = nil,
        executionPolicy: AgentExecutionPolicy,
        resumeSession: ModelSessionResume?,
        authority: (any Authority)?,
        reasoning: ReasoningEffortSelection? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.agentID = agentID
        self.contextID = contextID
        self.workspace = workspace
        self.executionPolicy = executionPolicy
        self.resumeSession = resumeSession
        self.authority = authority
    }
}

/// Host-owned extension point for model providers not built into Hail.
public typealias ModelEndpointProvider =
    @Sendable (ModelEndpointRequest) -> (any ModelEndpoint)?
