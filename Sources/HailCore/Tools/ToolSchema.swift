import AnyLanguageModel

/// Small construction helpers for the model schema value supplied by
/// AnyLanguageModel. The stored schema remains `GenerationSchema`; these
/// helpers only keep tool declarations readable at call sites.
public enum ToolSchema {
    public static func object(
        name: String,
        description: String,
        properties: [DynamicGenerationSchema.Property],
        dependencies: [DynamicGenerationSchema] = []
    ) -> GenerationSchema {
        do {
            return try GenerationSchema(
                root: DynamicGenerationSchema(
                    name: name,
                    description: description,
                    properties: properties
                ),
                dependencies: dependencies
            )
        } catch {
            preconditionFailure("Invalid tool schema \(name): \(error)")
        }
    }

    public static func union(
        name: String,
        description: String,
        choices: [DynamicGenerationSchema],
        dependencies: [DynamicGenerationSchema] = []
    ) -> GenerationSchema {
        do {
            return try GenerationSchema(
                root: DynamicGenerationSchema(
                    name: name,
                    description: description,
                    anyOf: choices
                ),
                dependencies: dependencies
            )
        } catch {
            preconditionFailure("Invalid tool schema \(name): \(error)")
        }
    }

    public static func string(
        name: String,
        description: String? = nil,
        choices: [String]? = nil
    ) -> DynamicGenerationSchema {
        if let choices, !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        return DynamicGenerationSchema(type: String.self)
    }

    public static func integer() -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Int.self)
    }

    public static func boolean() -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Bool.self)
    }

    public static func number() -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Double.self)
    }

    public static func array(of element: DynamicGenerationSchema) -> DynamicGenerationSchema {
        DynamicGenerationSchema(arrayOf: element)
    }
}
