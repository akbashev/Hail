import AnyLanguageModel
import HailCore

/// Builds the prompt handed to the summarize closure: the prior rolling
/// summary plus the messages about to be archived, rendered as a transcript.
enum SummaryPrompt {
    static func entries(
        priorSummary: GeneratedContent?,
        archived: [ChatMessage],
        agentID: AgentID
    ) -> [Transcript.Entry] {
        var transcript: [String] = []
        if let priorSummary { transcript.append("Summary so far:\n\(priorSummary.jsonString)") }
        for message in archived {
            transcript.append(render(message, agentID: agentID))
        }

        return [
            .instructions(
                .init(
                    segments: [
                        .text(
                            .init(
                                content: """
                                    You are compacting an agent's conversation history. Update the \
                                    running summary so it still covers everything the agent must \
                                    remember: decisions, user preferences, tasks in flight, and \
                                    important facts. Be concise; drop small talk and superseded details.
                                    """))
                    ],
                    toolDefinitions: []
                )),
            .prompt(.init(segments: [.text(.init(content: transcript.joined(separator: "\n")))])),
        ]
    }

    private static func render(_ message: ChatMessage, agentID: AgentID) -> String {
        switch message {
        case .text(let sender, let content, _):
            return "\(label(for: sender, agentID: agentID)): \(content)"
        case .response(let sender, let content, _):
            return "\(label(for: sender, agentID: agentID)): \(content.jsonString)"
        case .toolCall(let calls, _):
            let rendered = calls.map { "\($0.name)(\($0.arguments.jsonString))" }.joined(separator: ", ")
            return "assistant called tools: \(rendered)"
        case .assistantToolCall(let round, _):
            let content = round.narration.map { render($0.segments) } ?? ""
            let rendered = round.calls.map { "\($0.name)(\($0.arguments.jsonString))" }.joined(separator: ", ")
            let reasoning = round.reasoning.isEmpty ? "" : " reasoning: \(render(round.reasoning))"
            return "assistant: \(content)\(reasoning) called tools: \(rendered)"
        case .toolResult(_, let name, let output, _):
            return "\(name) result: \(render(output.transcriptSegments))"
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

    private static func render(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let value): return value.content
            case .structure(let value): return value.content.jsonString
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }
}
