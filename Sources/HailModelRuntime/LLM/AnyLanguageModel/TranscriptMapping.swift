import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Maps Hail's transcript entries to what an AnyLanguageModel request is made of: the
/// instructions, the history before the prompt, and the prompt the request answers. A request
/// always answers a prompt: tool calls and their outputs happen inside it, never between
/// requests.
enum TranscriptMapping {
    struct Request {
        let instructions: Instructions?
        let history: [Transcript.Entry]
        let prompt: Prompt
    }

    /// The request ends with something other than a prompt to answer.
    struct NoPrompt: Error, CustomStringConvertible {
        var description: String { "The request has no prompt to answer: its transcript ends with something else." }
    }

    static func request(from entries: [Transcript.Entry]) throws -> Request {
        var instructions: [Transcript.Segment] = []
        var history: [Transcript.Entry] = []
        for entry in entries {
            switch entry {
            case .instructions(let entryInstructions):
                instructions.append(contentsOf: entryInstructions.segments)
            case .prompt, .response, .toolCalls, .toolOutput, .reasoning:
                history.append(entry)
            }
        }
        guard case .prompt(let last)? = history.last else { throw NoPrompt() }
        history.removeLast()
        return Request(
            instructions: instructions.isEmpty
                ? nil : Instructions(instructions.map(\.description).joined(separator: "\n")),
            history: history,
            prompt: Prompt(last.segments.map(\.description).joined(separator: "\n"))
        )
    }
}
