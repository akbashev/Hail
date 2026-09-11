import AnyLanguageModel

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
        self.parameters = parameters
    }
}
