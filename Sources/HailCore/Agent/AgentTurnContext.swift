/// The canonical context available while resolving tools for one agent turn.
///
/// Hail deliberately exposes the normalized chat message rather than the
/// product-specific `AgentInput` value. Hosts may use the message to scope
/// tools to the current sender or request, while Hail remains unaware of the
/// host's domain semantics.
public struct AgentTurnContext: Sendable {
    public let agentID: AgentID
    public let sourceAgentID: AgentID
    public let turnID: TurnID
    public let message: ChatMessage
    /// Host-supplied identity of the input that started this turn.
    /// Hail treats it as opaque metadata for per-turn integrations.
    public let inputID: String?

    public init(
        agentID: AgentID,
        sourceAgentID: AgentID,
        turnID: TurnID,
        message: ChatMessage,
        inputID: String? = nil
    ) {
        self.agentID = agentID
        self.sourceAgentID = sourceAgentID
        self.turnID = turnID
        self.message = message
        self.inputID = inputID
    }
}
