import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A response as its snapshots come, each as the snapshot says it: its text, the tools called so
/// far, and what it used. It answered only if the model wrote after its last tool call; text
/// written before a call isn't an answer.
struct ResponseSoFar<Output: Generable> {
    /// How a response that came to its end ended.
    enum Ending {
        case answered(Output)
        /// The model wrote nothing after its last tool call.
        case wroteNothing
        /// The model wrote an answer that isn't the content asked for: `written` is what it wrote.
        case outOfShape(written: String)
    }

    private var text = ""
    private var calls = 0
    private var wroteAfterCalls: Int?
    /// The response is the last snapshot, once the stream ends: a snapshot that reads as complete
    /// JSON can still be partway, as FM's always do.
    private var last: (content: Output.PartiallyGenerated, raw: GeneratedContent)?
    /// The usage of the response's final request, as its snapshots report it: its input is how
    /// full the context is.
    private(set) var usage: LanguageModelSession.Usage?

    /// Takes the next snapshot.
    mutating func receive(_ snapshot: LanguageModelSession.ResponseStream<Output>.Snapshot) {
        calls = snapshot.transcriptEntries.reduce(0) { count, entry in
            guard case .toolCalls(let calls) = entry else { return count }
            return count + calls.count
        }
        usage = snapshot.usage
        last = (snapshot.content, snapshot.rawContent)
        guard Output.self == String.self else {
            wroteAfterCalls = calls
            return
        }
        guard case .string(let snapshotText) = snapshot.rawContent.kind else { return }
        let delta = Self.delta(from: snapshotText, after: &text)
        if !delta.trimmed().isEmpty { wroteAfterCalls = calls }
    }

    /// How the response ended, once its stream did.
    func ending() throws -> Ending {
        guard wroteAfterCalls == calls, let last else { return .wroteNothing }
        if let output = last.content as? Output { return .answered(output) }
        do {
            return .answered(try Output(last.raw))
        } catch {
            guard case .string(let text) = last.raw.kind else { return .outOfShape(written: last.raw.jsonString) }
            // JSON in a Markdown fence is that JSON: a model that fences its answer still answers.
            if let json = Self.fenced(text), let output = try? Output(GeneratedContent(json: json)) {
                return .answered(output)
            }
            // Plain text is all an object of one text property can say, so it says that.
            if let property = Output.generationSchema.soleTextProperty,
                let output = try? Output(GeneratedContent(properties: [property: text]))
            {
                return .answered(output)
            }
            return .outOfShape(written: text)
        }
    }

    /// What `text` holds when it's all one Markdown code block, ```` ```json ```` or a bare fence:
    /// the block's lines; `nil` for anything else.
    static func fenced(_ text: String) -> String? {
        let lines = text.trimmed().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let first = lines.first, let last = lines.last, first.hasPrefix("```"),
            String(last).trimmed() == "```"
        else { return nil }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    /// What a snapshot adds to the text before it: the suffix after `accumulated`.
    private static func delta(from snapshot: String, after accumulated: inout String) -> String {
        guard !snapshot.isEmpty else { return "" }
        if snapshot.hasPrefix(accumulated) {
            let start = snapshot.index(snapshot.startIndex, offsetBy: accumulated.count)
            let delta = String(snapshot[start...])
            accumulated = snapshot
            return delta
        }
        // A provider that replaces its partial snapshot is still represented faithfully: reset the
        // accumulator and publish the replacement.
        accumulated = snapshot
        return snapshot
    }
}

extension GenerationSchema {
    /// The name of an object's one property, when it's text the object must have, with no
    /// choices or pattern: the only thing such an object says, as plain text says it.
    var soleTextProperty: String? {
        guard let data = try? JSONEncoder().encode(self),
            case .object(var object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        if case .string(let reference)? = object["$ref"], case .object(let definitions)? = object["$defs"] {
            guard case .object(let definition)? = definitions[String(reference.dropFirst("#/$defs/".count))]
            else { return nil }
            object = definition
        }
        guard object["type"] == .string("object"),
            case .object(let properties)? = object["properties"], properties.count == 1,
            let (name, value) = properties.first, case .object(let property) = value,
            property["type"] == .string("string"),
            property["enum"] == nil, property["pattern"] == nil, property["const"] == nil,
            case .array(let required)? = object["required"], required.contains(.string(name))
        else { return nil }
        return name
    }
}
