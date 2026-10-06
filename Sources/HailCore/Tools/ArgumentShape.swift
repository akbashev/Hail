import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Arguments that don't fit a tool's schema, with the first part that doesn't, by its path, such as
/// `spec.receive[2].actions[0] needs action: one of set, add, …`.
public struct ArgumentMismatch: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}

extension Generable {
    /// Decodes arguments the way small models write them. As given if they fit; otherwise brought
    /// to the shape the schema asks for, the way typia's harness does: an object or a list sent as
    /// JSON text is read as one, and a number or a boolean where text was asked for is read as
    /// text. What still doesn't fit is named by its path.
    public init(leniently content: GeneratedContent) throws {
        if let decoded = try? Self(content) {
            self = decoded
            return
        }
        let schema = try ArgumentSchema(Self.generationSchema)
        self = try Self(content.conformed(to: schema.root, in: schema))
    }
}

/// A tool's schema as JSON Schema, read from its `GenerationSchema`.
struct ArgumentSchema {
    let root: Node
    let definitions: [String: Node]

    final class Node: Decodable, Sendable {
        let ref: String?
        let type: String?
        let properties: [String: Node]?
        let required: [String]?
        let items: Node?
        let choices: [String]?
        let anyOf: [Node]?
        let definitions: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case ref = "$ref", type, properties, required, items, choices = "enum", anyOf, definitions = "$defs"
        }
    }

    init(_ schema: GenerationSchema) throws {
        root = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(schema))
        definitions = root.definitions ?? [:]
    }

    func resolve(_ node: Node) -> Node {
        guard let ref = node.ref, let name = ref.split(separator: "/").last, let target = definitions[String(name)] else {
            return node
        }
        return resolve(target)
    }
}

extension GeneratedContent {
    func conformed(
        to node: ArgumentSchema.Node, in schema: ArgumentSchema, at path: String = ""
    ) throws(ArgumentMismatch) -> GeneratedContent {
        let node = schema.resolve(node)
        if let options = node.anyOf {
            if case .null = kind { return self }
            var first: ArgumentMismatch?
            for option in options where schema.resolve(option).type != "null" {
                do { return try conformed(to: option, in: schema, at: path) } catch { first = first ?? error }
            }
            throw first ?? ArgumentMismatch(description: "\(Self.naming(path)) doesn't fit.")
        }
        switch node.type {
        case "object":
            guard case .structure(let properties, let keys) = try readingJSON(opening: "{", at: path).kind else {
                throw ArgumentMismatch(description: "\(Self.naming(path)) is `\(shown)`, but it's an object. \(Self.parts(of: node))")
            }
            let missing = (node.required ?? []).filter { key in
                if case .null? = properties[key]?.kind { return true }
                return properties[key] == nil
            }
            let unknown = node.properties.map { known in keys.filter { known[$0] == nil } } ?? []
            if let key = missing.first {
                var said = "\(Self.naming(path)) needs `\(key)`"
                if let choices = node.properties?[key].map(schema.resolve)?.choices {
                    said += ", one of \(choices.joined(separator: ", "))"
                }
                if !unknown.isEmpty {
                    said += "; \(unknown.map { "`\($0)`" }.joined(separator: ", ")) isn't one of its parts"
                }
                throw ArgumentMismatch(description: said + ". \(Self.parts(of: node))")
            }
            if let key = unknown.first {
                throw ArgumentMismatch(description: "\(Self.naming(path)) has `\(key)`, which isn't one of its parts. \(Self.parts(of: node))")
            }
            var conformed: [String: GeneratedContent] = [:]
            for key in keys {
                guard let value = properties[key] else { continue }
                if let property = node.properties?[key] {
                    conformed[key] = try value.conformed(to: property, in: schema, at: path.isEmpty ? key : "\(path).\(key)")
                } else {
                    conformed[key] = value
                }
            }
            return GeneratedContent(kind: .structure(properties: conformed, orderedKeys: keys))
        case "array":
            guard case .array(let items) = try readingJSON(opening: "[", at: path).kind else {
                throw ArgumentMismatch(description: "\(Self.naming(path)) is `\(shown)`, but it's a list.")
            }
            guard let item = node.items else { return GeneratedContent(kind: .array(items)) }
            var conformed: [GeneratedContent] = []
            for (index, value) in items.enumerated() {
                conformed.append(try value.conformed(to: item, in: schema, at: "\(path)[\(index)]"))
            }
            return GeneratedContent(kind: .array(conformed))
        case "string":
            let text: String
            switch kind {
            case .string(let string): text = string
            case .number, .bool, .array, .structure: text = jsonString
            default:
                throw ArgumentMismatch(description: "\(Self.naming(path)) is `\(shown)`, but it's text.")
            }
            if let choices = node.choices, !choices.contains(text) {
                throw ArgumentMismatch(
                    description: "\(Self.naming(path)) is `\(text)`, but it's one of \(choices.joined(separator: ", ")).")
            }
            return GeneratedContent(kind: .string(text))
        case "integer", "number":
            switch kind {
            case .number: return self
            case .string(let text):
                if let number = Double(text.trimmingCharacters(in: .whitespaces)) { return GeneratedContent(kind: .number(number)) }
            default: break
            }
            throw ArgumentMismatch(description: "\(Self.naming(path)) is `\(shown)`, but it's a number.")
        case "boolean":
            switch kind {
            case .bool: return self
            case .string("true"): return GeneratedContent(kind: .bool(true))
            case .string("false"): return GeneratedContent(kind: .bool(false))
            default: throw ArgumentMismatch(description: "\(Self.naming(path)) is `\(shown)`, but it's true or false.")
            }
        default:
            return self
        }
    }

    /// The JSON object or list this text holds, for a model that sent one as text, such as
    /// `"spec": "{\"fields\": …}"`; otherwise the content as it is. It's read strictly: what
    /// doesn't read is said, not read in part.
    private func readingJSON(opening: Character, at path: String) throws(ArgumentMismatch) -> GeneratedContent {
        guard case .string(let text) = kind else { return self }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == opening else { return self }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            return try GeneratedContent(json: trimmed)
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(error)"
            throw ArgumentMismatch(description: "\(Self.naming(path)) is JSON text that doesn't read: \(reason)")
        }
    }

    /// The content as written, cut short.
    private var shown: String {
        let text = jsonString
        return text.count > 60 ? text.prefix(60) + "…" : text
    }

    private static func naming(_ path: String) -> String {
        path.isEmpty ? "The call" : "`\(path)`"
    }

    /// `Its parts: action, field, value.`, needed ones first.
    private static func parts(of node: ArgumentSchema.Node) -> String {
        guard let properties = node.properties, !properties.isEmpty else { return "" }
        let required = node.required ?? []
        let names = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
        return "Its parts: \(names.joined(separator: ", "))."
    }
}
