import AnyLanguageModel
import Crypto

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Per-element content digests before provider-specific request serialization.
///
/// Round N+1 of a tool loop should share its content prefix with round N.
/// Token counts cannot show where two requests diverge; comparing the
/// journaled chains can. The first differing index between two rounds is
/// the first element whose content changed. Provider transformations and
/// model tokenization are not represented by these diagnostics.
public enum RequestContentHash {
    /// One cumulative digest per element: the tool schemas first, then each
    /// message in request order.
    public static func chain(
        tools: [ToolDefinition],
        messages: [Transcript.Entry]
    ) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var previous = Data()
        var digests: [String] = []

        func absorb(_ value: some Encodable) {
            var input = previous
            if let data = try? encoder.encode(value) {
                input.append(data)
            }
            let digest = Data(SHA256.hash(data: input))
            digests.append(digest.prefix(8).hexString)
            previous = digest
        }

        absorb(tools)
        for message in messages {
            absorb(withoutLocalIDs(message))
        }
        return digests
    }

    // Transcript/segment UUIDs are local bookkeeping, not prompt content.
    // Tool invocation IDs are preserved: providers use them to match outputs.
    private static func withoutLocalIDs(_ entry: Transcript.Entry) -> Transcript.Entry {
        switch entry {
        case .instructions(var value):
            value.id = ""
            value.segments = value.segments.map(withoutLocalID)
            return .instructions(value)
        case .prompt(var value):
            value.id = ""
            value.segments = value.segments.map(withoutLocalID)
            return .prompt(value)
        case .response(var value):
            value.id = ""
            value.segments = value.segments.map(withoutLocalID)
            return .response(value)
        case .toolCalls(var value):
            value.id = ""
            return .toolCalls(value)
        case .toolOutput(var value):
            value.segments = value.segments.map(withoutLocalID)
            return .toolOutput(value)
        case .reasoning(var value):
            value.id = ""
            value.segments = value.segments.map(withoutLocalID)
            return .reasoning(value)
        }
    }

    private static func withoutLocalID(_ segment: Transcript.Segment) -> Transcript.Segment {
        switch segment {
        case .text(var value):
            value.id = ""
            return .text(value)
        case .structure(var value):
            value.id = ""
            return .structure(value)
        case .image(var value):
            value.id = ""
            return .image(value)
        }
    }

}
