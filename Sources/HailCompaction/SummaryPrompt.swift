import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The summarizer's task text, composed from the report type itself.
///
/// A typed compaction report is a ``Generable`` type, and its documentation
/// travels with it: the type-level description and every field guide are part
/// of the generation schema the model already receives. The task instruction
/// is therefore derived from that schema, not supplied separately — the type
/// is the single source of truth for what the model must produce. Types
/// without a description keep the built-in plain-text summary task.
public enum CompactionTask {
    /// The minimal lifecycle framing Hail owns: what is happening and what
    /// follows in the prompt. The report type's own description carries
    /// everything about the expected output.
    private static let framing = """
        You are compacting an agent's conversation history into the report \
        described below. The messages being archived follow.
        """

    /// The legacy task for the built-in plain-text rolling summary, used
    /// when the report type carries no description of its own.
    private static let plainTextSummary = """
        You are compacting an agent's conversation history. Update the \
        running summary so it still covers everything the agent must \
        remember: decisions, user preferences, tasks in flight, and \
        important facts. Be concise; drop small talk and superseded details.
        """

    public static func instructions<Report: Generable>(for type: Report.Type) -> String {
        guard let description = schemaDescription(of: type) else {
            return plainTextSummary
        }
        return "\(framing)\n\n\(description)"
    }

    /// Reads the type-level description back from the schema the macro
    /// compiled into the report type. The description is prompt material;
    /// this is the same encoding the endpoint already sends as the output
    /// format, so what the model reads here is exactly what constrains it.
    /// Macro-built schemas address the root type through `$defs` and `$ref`,
    /// so both shapes are resolved.
    private static func schemaDescription<Report: Generable>(of type: Report.Type) -> String? {
        guard let data = try? JSONEncoder().encode(type.generationSchema),
            let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data)
        else { return nil }
        if let description = envelope.description, !description.isEmpty {
            return description
        }
        guard
            let ref = envelope.ref?.replacingOccurrences(of: "#/$defs/", with: ""),
            let description = envelope.defs?[ref]?.description,
            !description.isEmpty
        else { return nil }
        return description
    }
}

/// Top-level shape of an encoded generation schema; only the description is
/// read back.
private struct SchemaEnvelope: Decodable {
    let description: String?
    let ref: String?
    let defs: [String: Definition]?

    private enum CodingKeys: String, CodingKey {
        case description
        case ref = "$ref"
        case defs = "$defs"
    }

    struct Definition: Decodable {
        let description: String?
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
        task: String
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
                                content: task
                            ))
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
            let text = render(output.transcriptSegments)
            let bounded =
                text.count > Self.maximumToolResultCharacters
                ? String(text.prefix(Self.maximumToolResultCharacters)) + " …[truncated]"
                : text
            return "\(name) result: \(bounded)"
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
