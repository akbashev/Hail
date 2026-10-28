import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Provider-neutral information needed to expose a Hail tool to a model.
///
/// The argument schema is AnyLanguageModel's `GenerationSchema`, so schema
/// generation, unions, and provider serialization have one source of truth.
/// Effect authorization and execution remain owned by Hail's `Tool` protocol.
public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema

    public init(name: String, description: String, parameters: GenerationSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters.withShortDefinitionNames()
    }
}

extension GenerationSchema {
    /// The schema with each definition named by the last part of its name, such as `Value` for
    /// `MyModule.Spec.Value`, and numbered only where two would share a name. A model reads
    /// every name in every request, and needs them only to tell definitions apart.
    func withShortDefinitionNames() -> GenerationSchema {
        guard let data = try? JSONEncoder().encode(self),
            case .object(var schema)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let definitions)? = schema["$defs"]
        else { return self }
        var names: [String: String] = [:]
        var taken: Set<String> = []
        for name in definitions.keys.sorted() {
            let last = name.split(separator: ".").last.map(String.init) ?? name
            var short = last
            var number = 2
            while taken.contains(short) {
                short = "\(last)\(number)"
                number += 1
            }
            taken.insert(short)
            names[name] = short
        }
        func renamed(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                var result: [String: JSONValue] = [:]
                for (key, member) in object {
                    if key == "$ref", case .string(let ref) = member, ref.hasPrefix("#/$defs/"),
                        let short = names[String(ref.dropFirst("#/$defs/".count))]
                    {
                        result[key] = .string("#/$defs/" + short)
                    } else {
                        result[key] = renamed(member)
                    }
                }
                return .object(result)
            case .array(let array):
                return .array(array.map(renamed))
            default:
                return value
            }
        }
        var shortened: [String: JSONValue] = [:]
        for (name, definition) in definitions { shortened[names[name] ?? name] = renamed(definition) }
        if case .object(let renamedSchema) = renamed(.object(schema)) { schema = renamedSchema }
        schema["$defs"] = .object(shortened)
        guard let renamedData = try? JSONEncoder().encode(JSONValue.object(schema)),
            let result = try? JSONDecoder().decode(GenerationSchema.self, from: renamedData)
        else { return self }
        return result
    }
}
