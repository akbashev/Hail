import AnyLanguageModel
import CryptoKit

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Deterministic per-element digest chain over one outbound model request.
///
/// Round N+1 of a tool loop should share its rendered prefix with round N.
/// Token counts cannot show where two requests diverge; comparing the
/// journaled chains can. The first differing index between two rounds is
/// the first element whose rendering changed.
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
            digests.append(digest.prefix(8).map { String(format: "%02x", $0) }.joined())
            previous = digest
        }

        absorb(tools)
        for message in messages {
            absorb(message)
        }
        return digests
    }
}
