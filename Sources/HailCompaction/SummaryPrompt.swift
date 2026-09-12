import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The summarizer's task text.
///
/// A typed compaction report is a ``Generable`` type whose schema and field
/// guides are attached to the request's output format; the built-in task
/// below is the fallback instruction. Recovering the type-level description
/// for the prompt would require resolving `$defs`/`$ref` shapes here, which
/// Hail deliberately leaves to the schema's owner.
public enum CompactionTask {
    /// The built-in plain-text rolling summary task.
    private static let plainTextSummary = """
        You are compacting an agent's conversation history. Rewrite the \
        running summary to reflect the CURRENT state of the conversation: \
        what the user is trying to do now, decisions made, preferences \
        revealed, and tasks in flight. Drop topics that are no longer \
        active and details superseded by newer messages. Be concise.
        """

    public static func instructions<Report: Generable>(for type: Report.Type) -> String {
        plainTextSummary
    }
}

/// Builds the prompt handed to the summarize closure: the prior rolling
/// summary plus the messages about to be archived, rendered as a transcript.
enum SummaryPrompt {
    /// Tool results are reference material for the summarizer, not transcript
    /// to preserve verbatim; an excerpt carries everything a summary needs.
    private static let maximumToolResultCharacters = 2_000

    static func entries(
        priorSummary: GeneratedContent?,
        archived: [ChatMessage],
        agentID: AgentID,
        task: String,
        outputBudget: Int? = nil
    ) -> [Transcript.Entry] {
        var transcript: [String] = []
        if let priorSummary { transcript.append("Summary so far:\n\(priorSummary.jsonString)") }
        for message in archived {
            if let rendered = render(message, agentID: agentID) {
                transcript.append(rendered)
            }
        }

        var taskText = task
        if let outputBudget, outputBudget > 0 {
            taskText += """

                The report must fit within \(outputBudget) tokens. Keep entries few \
                and short: a concise report that fits is worth far more than a \
                complete one that does not.
                """
        }

        return [
            .instructions(
                .init(
                    segments: [
                        .text(
                            .init(
                                content: taskText
                            ))
                    ],
                    toolDefinitions: []
                )),
            .prompt(.init(segments: [.text(.init(content: transcript.joined(separator: "\n")))])),
        ]
    }

    private static func render(_ message: ChatMessage, agentID: AgentID) -> String? {
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
            let text = render(output.transcriptSegments)
            let bounded =
                text.count > Self.maximumToolResultCharacters
                ? String(text.prefix(Self.maximumToolResultCharacters)) + " …[truncated]"
                : text
            return "\(name) result: \(bounded)"
        case .failure:
            // Display-only; never summary material.
            return nil
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
