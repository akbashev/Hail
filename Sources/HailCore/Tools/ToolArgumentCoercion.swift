import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Small models loosely type tool arguments — a number arrives as the
/// string "1". The declared schema knows which fields are scalar, so the
/// coercion is schema-driven, not heuristic: for every property declared
/// integer, number, or boolean, a string value that parses is replaced
/// with the typed value before `Input` decoding. Anything that does not
/// parse is left untouched for the decoder to reject with a precise error.
enum ToolArgumentCoercion {
    static func coerce(
        _ arguments: GeneratedContent,
        as schema: GenerationSchema
    ) -> GeneratedContent {
        guard
            let data = try? JSONEncoder().encode(schema),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let argumentsObject = try? JSONSerialization.jsonObject(with: Data(arguments.jsonString.utf8))
        else {
            return arguments
        }
        var root = object
        let defs = (root["$defs"] as? [String: Any]) ?? [:]
        guard var properties = (resolve(root, defs: defs)["properties"] as? [String: Any]) else {
            return arguments
        }
        guard var coerced = argumentsObject as? [String: Any] else {
            return arguments
        }
        coerceProperties(&properties, values: &coerced, defs: defs)
        root["properties"] = properties
        guard
            let rewritten = try? JSONSerialization.data(withJSONObject: coerced),
            let string = String(data: rewritten, encoding: .utf8),
            let result = try? GeneratedContent(json: string)
        else {
            return arguments
        }
        return result
    }

    private static func coerceProperties(
        _ properties: inout [String: Any],
        values: inout [String: Any],
        defs: [String: Any]
    ) {
        for (key, property) in properties {
            guard let property = property as? [String: Any],
                let value = values[key]
            else { continue }
            values[key] = coerceValue(value, as: property, defs: defs)
        }
    }

    private static func coerceValue(_ value: Any, as schema: [String: Any], defs: [String: Any]) -> Any {
        let resolved = resolve(schema, defs: defs)
        if let type = resolved["type"] as? String {
            switch (type, value) {
            case ("integer", let text as String):
                if let number = Int(text) { return number }
            case ("number", let text as String):
                if let number = Double(text) { return number }
            case ("boolean", let text as String):
                switch text {
                case "true": return true
                case "false": return false
                default: break
                }
            case ("object", let object as [String: Any]):
                var properties = (resolved["properties"] as? [String: Any]) ?? [:]
                var values = object
                coerceProperties(&properties, values: &values, defs: defs)
                return values
            case ("array", let items as [Any]):
                if let itemSchema = resolved["items"] as? [String: Any] {
                    return items.map { coerceValue($0, as: itemSchema, defs: defs) }
                }
            default:
                break
            }
        }
        return value
    }

    private static func resolve(_ schema: [String: Any], defs: [String: Any]) -> [String: Any] {
        guard let reference = schema["$ref"] as? String,
            let name = reference.split(separator: "/").last,
            let definition = defs[String(name)] as? [String: Any]
        else {
            return schema
        }
        return resolve(definition, defs: defs)
    }
}
