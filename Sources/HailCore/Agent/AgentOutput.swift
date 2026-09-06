import AnyLanguageModel

/// A value that can be produced as the result of an agent turn.
///
/// Conforming types describe how the model must return them: either as plain
/// text or by calling a dedicated reporting tool. The runtime uses this
/// contract to drive the model adapter without knowing the domain meaning of
/// the value.
public protocol AgentOutput: Codable & Sendable & Generable
where PartiallyGenerated: Codable & Sendable {
    /// Describes how the model must produce this output.
    static var outputContract: AgentOutputContract { get }
}

/// The form a model must use to produce an ``AgentOutput``.
public enum AgentOutputContract: Codable, Sendable {
    /// The model streams plain text; no special tool is required.
    case plainText

    /// The model must call a dedicated reporting tool with the given schema.
    ///
    /// The tool name is also used by adapters such as ``KimiCodeEndpoint`` to
    /// intercept the call and decode the arguments into the typed output.
    case reportTool(name: String, schema: LLMToolSchema)
}

extension String: AgentOutput {
    public static var outputContract: AgentOutputContract {
        .plainText
    }
}
