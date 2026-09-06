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
    static func transcriptAndPrompt(
        from input: ModelInput
    ) throws -> (transcript: Transcript, prompt: Prompt) {
        var entries: [Transcript.Entry] = []
        var toolCallNames: [String: String] = [:]

        var systemSegments: [Transcript.Segment] = []

        for inputEntry in input.entries {
            switch inputEntry {
            case .toolOutput(let callID, let name, let output):
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                entries.append(
                    .toolOutput(
                        Transcript.ToolOutput(
                            id: callID,
                            toolName: name,
                            segments: try segments(for: output)
                        )))

            case .message(let message):
                switch message.role {
            case .system:
                systemSegments.append(.text(.init(content: message.content)))

            case .user:
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                entries.append(
                    .prompt(
                        Transcript.Prompt(
                            segments: segments(for: message)
                        )))

            case .assistant:
                flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    let calls = try toolCalls.map { call in
                        Transcript.ToolCall(
                            id: call.id,
                            toolName: call.function.name,
                            arguments: try GeneratedContent(json: call.function.arguments)
                        )
                    }
                    for call in toolCalls {
                        toolCallNames[call.id] = call.function.name
                    }
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                } else {
                    entries.append(
                        .response(
                            Transcript.Response(
                                assetIDs: [],
                                segments: segments(for: message)
                            ))
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
                            segments: segments(for: message)
                        )))
                }
            }
        }

        flushSystemSegments(into: &entries, segments: &systemSegments, toolNames: toolCallNames)

        // If the last message was from the user, use it as the active prompt and
        // remove it from the transcript (respond(to:) will append it again).
        if let last = entries.last,
            case .prompt(let lastPrompt) = last
        {
            entries.removeLast()
            return (
                Transcript(entries: entries),
                Prompt(lastPrompt.segments.map(\.description).joined(separator: "\n"))
            )
        }

        return (Transcript(entries: entries), Prompt(""))
    }

    private static func segments(for output: ToolOutput) throws -> [Transcript.Segment] {
        switch output {
        case .text(let text):
            return [.text(.init(content: text))]

        case .data(let data):
            let contentType = data.normalizedContentType
            if data.isTextLike {
                return [.text(.init(content: String(decoding: data.body, as: UTF8.self)))]
            }
            if contentType.hasPrefix("image/") {
                return [
                    .text(.init(content: output.transcript)),
                    .image(.init(data: data.body, mimeType: contentType)),
                ]
            }
            throw ModelEndpointError.invalidRequest(
                "AnyLanguageModel cannot map tool data with content type \(contentType); the provider adapter does not support this media type."
            )
        }
    }

    private static func segments(for message: LLMMessage) -> [Transcript.Segment] {
        guard !message.content.isEmpty else { return [] }
        return [.text(.init(content: message.content))]
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
