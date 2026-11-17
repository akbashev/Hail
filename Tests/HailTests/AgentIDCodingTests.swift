import Foundation
import HailCore
import Testing

/// An agent's id crosses the wire as its role and its context, each as it was, whatever either
/// holds: its raw value, `<role>-<context>`, can't say where a role with a hyphen ends.
struct AgentIDCodingTests {
    @Test func anAgentIDIsReadBackAsItWasWritten() throws {
        let agent = AgentID(
            role: Role("CB4B146B-0000-4000-8000-000000000001"),
            contextID: AgentContextID("space-1/conversation-2"))
        let crossed = try JSONDecoder().decode(AgentID.self, from: JSONEncoder().encode(agent))
        #expect(crossed == agent)
        #expect(crossed.role == agent.role)
        #expect(crossed.contextID == agent.contextID)
    }
}
