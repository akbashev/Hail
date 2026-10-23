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
        You are compacting an agent's history history. Rewrite the \
        running summary to reflect the CURRENT state of the history: \
        what the user is trying to do now, decisions made, preferences \
        revealed, and tasks in flight. Drop topics that are no longer \
        active and details superseded by newer messages. Be concise.
        """

    public static func instructions<Report: Generable>(for type: Report.Type) -> String {
        plainTextSummary
    }
}

/// Builds the prompt handed to the summarize closure: the summary so far, then the turns being
/// folded, as what was said, what was called and what came back, and the answer. Inputs that stay
/// word for word are still shown, so the summary can say what was done about each; the open
/// turn's work, when it's folded, is marked as this turn's, so far.
enum SummaryPrompt {
    /// Tool results are reference material for the summarizer, not transcript
    /// to preserve verbatim; an excerpt carries everything a summary needs.
    private static let maximumToolResultCharacters = 2_000

    static func entries(
        priorSummary: AgentHistory.Summary?,
        fold: AgentHistory.Fold,
        task: String,
        outputBudget: Int
    ) -> [Transcript.Entry] {
        // Earlier inputs no longer kept word for word: the summary is now all there is of them.
        let transcript =
            (priorSummary.map { ["Summary so far:\n\($0.context.jsonString)"] } ?? [])
            + fold.dropped.map { render($0.input) }
            + fold.folded.flatMap(render)
            + (fold.foldedWork.map { ["This turn so far, still in progress:"] + render($0) } ?? [])

        let taskText =
            task + """

                The report must fit within \(outputBudget) tokens. Keep entries few \
                and short: a concise report that fits is worth far more than a \
                complete one that does not.
                """

        return [
            .instructions(.init(segments: [.text(.init(content: taskText))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: transcript.joined(separator: "\n")))])),
        ]
    }

    private static func render(_ turn: AgentHistory.ClosedTurn) -> [String] {
        let answer: [String] =
            switch turn.outcome {
            case .replied(let reply): ["assistant: \(text(of: reply.content))"]
            case .failed, .cancelled, .interrupted: []
            }
        return [render(turn.input)] + turn.steps.map(render) + answer
    }

    private static func render(_ turn: AgentHistory.OpenTurn) -> [String] {
        [render(turn.input)] + turn.steps.map(render)
    }

    private static func render(_ input: AgentHistory.Input) -> String {
        "user: \(text(of: input.content))"
    }

    private static func render(_ step: AgentHistory.Step) -> String {
        switch step {
        case .called(let call, _):
            return "assistant called \(call.name)(\(call.arguments.jsonString))"
        case .resulted(let result, _):
            let text = render(result.output.transcriptSegments)
            let bounded =
                text.count > Self.maximumToolResultCharacters
                ? String(text.prefix(Self.maximumToolResultCharacters)) + " …[truncated]"
                : text
            return "\(result.name) result: \(bounded)"
        case .noticed(let notice, _):
            return "runtime: \(notice.words)"
        }
    }

    private static func text(of content: GeneratedContent) -> String {
        if case .string(let text) = content.kind { return text }
        return content.jsonString
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
