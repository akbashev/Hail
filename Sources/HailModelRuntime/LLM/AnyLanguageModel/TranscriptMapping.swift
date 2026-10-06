import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Maps Hail's transcript entries to an AnyLanguageModel `Transcript`
/// plus the final `Prompt` that should be sent to `LanguageModelSession.respond(to:)`.
enum TranscriptMapping {
    /// Returns a transcript seeded with the conversation history and the prompt
    /// that should be passed to the model. If the last message is a user message,
    /// it becomes the prompt; otherwise an empty prompt is used and the history
    /// is left in the transcript.
    static func transcriptAndPrompt(
        from entries: [Transcript.Entry]
    ) throws -> (transcript: Transcript, prompt: Prompt) {
        var transcriptEntries: [Transcript.Entry] = []
        var systemSegments: [Transcript.Segment] = []

        for entry in entries {
            switch entry {
            case .instructions(let instructions):
                systemSegments.append(contentsOf: instructions.segments)
            case .prompt, .response, .toolCalls, .toolOutput, .reasoning:
                flushSystemSegments(into: &transcriptEntries, segments: &systemSegments)
                transcriptEntries.append(entry)
            }
        }

        flushSystemSegments(into: &transcriptEntries, segments: &systemSegments)

        // If the last message was from the user, use it as the active prompt and
        // remove it from the transcript (respond(to:) will append it again).
        if let last = transcriptEntries.last, case .prompt(let lastPrompt) = last {
            transcriptEntries.removeLast()
            return (
                Transcript(entries: transcriptEntries),
                Prompt(lastPrompt.segments.map(\.description).joined(separator: "\n"))
            )
        }

        return (Transcript(entries: transcriptEntries), Prompt(""))
    }

    private static func flushSystemSegments(
        into entries: inout [Transcript.Entry],
        segments: inout [Transcript.Segment],
    ) {
        guard !segments.isEmpty else { return }
        entries.append(
            .instructions(
                Transcript.Instructions(
                    segments: segments,
                    toolDefinitions: []
                )))
        segments.removeAll(keepingCapacity: true)
    }
}
