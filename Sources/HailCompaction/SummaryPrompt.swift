import HailCore

/// Builds the prompt handed to the summarize closure: the prior rolling
/// summary plus the messages about to be archived, rendered as a transcript.
enum SummaryPrompt {
    static func messages(
        priorSummary: String?,
        archived: [ChatMessage],
        agentID: AgentID
    ) -> [LLMMessage] {
        var transcript: [String] = []
        if let priorSummary, !priorSummary.isEmpty {
            transcript.append("Summary so far: \(priorSummary)")
        }
        for message in archived {
            transcript.append(render(message, agentID: agentID))
        }

        return [
            LLMMessage(
                role: .system,
                content: """
                    You are compacting an agent's conversation history. Update the \
                    running summary so it still covers everything the agent must \
                    remember: decisions, user preferences, tasks in flight, and \
                    important facts. Be concise; drop small talk and superseded details.
                    """
            ),
            LLMMessage(role: .user, content: transcript.joined(separator: "\n")),
        ]
    }

    private static func render(_ message: ChatMessage, agentID: AgentID) -> String {
        switch message {
        case .text(let sender, let content, _):
            return "\(label(for: sender, agentID: agentID)): \(content)"
        case .response(let sender, let payload, _):
            let content = String(decoding: payload, as: UTF8.self)
            return "\(label(for: sender, agentID: agentID)): \(content)"
        case .toolCall(let calls, _):
            let rendered = calls.map { "\($0.name)(\($0.arguments.json))" }.joined(separator: ", ")
            return "assistant called tools: \(rendered)"
        case .toolResult(_, let content, _):
            return "tool result: \(content)"
        case .failure(let error, _):
            return "turn failed: \(error)"
        case .decisionRequest(_, let question, _, _):
            return "decision requested: \(question)"
        case .decisionResolved(_, let question, let resolution, _, _):
            return "decision resolved: \(question) → \(resolution)"
        }
    }

    private static func label(for sender: String, agentID: AgentID) -> String {
        sender == agentID.rawValue ? "assistant" : sender
    }
}
