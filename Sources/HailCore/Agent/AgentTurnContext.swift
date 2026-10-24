/// The canonical context available while resolving tools for one agent turn.
///
import AnyLanguageModel

/// What the current turn answers, plus stable turn metadata used while composing tools. This is
/// domain context, not the model transcript sent to an endpoint.
public struct AgentTurnContext: Sendable {
    public let agentID: AgentID
    public let turnID: TurnID
    public let input: AgentHistory.Input

    public init(agentID: AgentID, turnID: TurnID, input: AgentHistory.Input) {
        self.agentID = agentID
        self.turnID = turnID
        self.input = input
    }
}
