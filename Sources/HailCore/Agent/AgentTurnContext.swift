/// The canonical context available while resolving tools for one agent turn.
///
import AnyLanguageModel

/// What the current turn answers, plus stable turn metadata used while composing tools. This is
/// domain context, not the model transcript sent to an endpoint.
public struct AgentTurnContext: Sendable {
    public let agentID: AgentID
    public let turnID: TurnID
    public let input: AgentHistory.Input
    /// Host-supplied identity of the input that started this turn.
    /// Hail treats it as opaque metadata for per-turn integrations.
    public let inputID: String?

    public init(
        agentID: AgentID,
        turnID: TurnID,
        input: AgentHistory.Input,
        inputID: String? = nil
    ) {
        self.agentID = agentID
        self.turnID = turnID
        self.input = input
        self.inputID = inputID
    }
}
