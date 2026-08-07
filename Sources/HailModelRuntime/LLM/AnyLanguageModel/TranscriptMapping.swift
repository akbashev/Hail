import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Maps Hail's `LLMMessage` thread to an AnyLanguageModel `Transcript`
/// plus the final `Prompt` that should be sent to `LanguageModelSession.respond(to:)`.
enum TranscriptMapping {
    /// Returns a transcript seeded with the conversation history and the prompt
    /// that should be passed to the model. If the last message is a user message,
    /// it becomes the prompt; otherwise an empty prompt is used and the history
    /// is left in the transcript.
    static func transcriptAndPrompt(from messages: [LLMMessage]) -> (Transcript, Prompt) {
        var entries: [Transcript.Entry] = []
        var toolCallNames: [String: String] = [:]

        var systemSegments: [Transcript.Segment] = []

        for message in messages {
            switch message.role {
            case .system:
                systemSegments.append(.text(.init(content: message.content)))

            case .user:
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: message.content))])))

            case .assistant:
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    let calls = toolCalls.map { call in
                        Transcript.ToolCall(
                            id: call.id,
                            toolName: call.function.name,
                            arguments: (try? GeneratedContent(json: call.function.arguments)) ?? GeneratedContent("{}")
                        )
                    }
                    for call in toolCalls {
                        toolCallNames[call.id] = call.function.name
                    }
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                } else {
                    entries.append(
                        .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: message.content))]))
                    )
                }

            case .tool:
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                let toolName = message.toolCallID.flatMap { toolCallNames[$0] } ?? "unknown"
                entries.append(
                    .toolOutput(
                        Transcript.ToolOutput(
                            id: message.toolCallID ?? UUID().uuidString,
                            toolName: toolName,
                            segments: [.text(.init(content: message.content))]
                        )))
            }
        }

        flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)

        // If the last message was from the user, use it as the active prompt and
        // remove it from the transcript (respond(to:) will append it again).
        if let last = entries.last,
            case .prompt(let lastPrompt) = last,
            let text = lastPrompt.segments.first?.description
        {
            entries.removeLast()
            return (Transcript(entries: entries), Prompt(text))
        }

        return (Transcript(entries: entries), Prompt(""))
    }

    private static func flushSystemSegments(
        into entries: inout [Transcript.Entry],
        segments: inout [Transcript.Segment],
        toolNames: [String: String]
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

// MARK: - GeneratedContent fallback

extension GeneratedContent {
    fileprivate init?(_ json: String) {
        try? self.init(json: json)
    }
}
