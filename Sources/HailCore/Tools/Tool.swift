import AnyLanguageModel
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Raw content produced by a tool. It preserves transport data and metadata;
/// interpreting the MIME type belongs to the model adapter.
public struct ToolData: Sendable {
    public let body: Data
    public let contentType: String?
    public let source: URL?

    public init(body: Data, contentType: String? = nil, source: URL? = nil) {
        self.body = body
        self.contentType = contentType
        self.source = source
    }

    /// A normalized MIME type for provider capability checks. Unknown or
    /// missing types remain opaque binary data; no business-level media
    /// taxonomy is introduced here.
    public var normalizedContentType: String {
        contentType?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? "application/octet-stream"
    }

    public var isTextLike: Bool {
        normalizedContentType.hasPrefix("text/")
            || normalizedContentType == "application/json"
            || normalizedContentType.hasSuffix("+json")
            || normalizedContentType == "application/xml"
            || normalizedContentType.hasSuffix("+xml")
    }
}

public enum ToolOutput: Sendable {
    case text(String)
    case data(ToolData)

    public var transcript: String {
        switch self {
        case .text(let text):
            return text
        case .data(let data):
            let source = data.source.map { " from \($0.absoluteString)" } ?? ""
            let type = data.normalizedContentType
            return "Fetched \(data.body.count) bytes\(source) with content type \(type)."
        }
    }
}

public struct ToolArguments: Codable, Sendable, Equatable, CustomStringConvertible {
    public let json: String

    public init(json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        self.json = trimmed.isEmpty ? "{}" : trimmed
    }

    public init<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        self.json = String(data: data, encoding: .utf8) ?? "{}"
    }

    public static let empty = ToolArguments(json: "{}")

    public var data: Data {
        Data(json.utf8)
    }

    public var description: String {
        json
    }
}

/// The model input for a tool command that takes no arguments.
public struct EmptyToolInput: Generable, Sendable {
    public init() {}

    public init(_ content: GeneratedContent) throws {
        guard case .structure(let properties, _) = content.kind,
            properties.isEmpty
        else {
            throw GeneratedContentConversionError.typeMismatch
        }
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            description: "This command takes no arguments.",
            properties: []
        )
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }
}

public protocol Tool<Input>: Sendable {
    /// Model-facing arguments. `Generable` owns both the schema sent to the
    /// provider and conversion from provider-generated content.
    associatedtype Input: Generable & Sendable
    associatedtype Effect: ScopedEffect

    var name: String { get }
    var description: String { get }
    var schema: ToolDefinition { get }
    /// Pure: decoded model input to the concrete effect being requested.
    func effect(for input: Input) throws -> Effect

    /// Runs only after the registry has authorized the effect and vended its
    /// non-escapable token.
    func run(input: Input, token: borrowing EffectToken<Effect>) async throws -> String

    func runOutput(input: Input, token: borrowing EffectToken<Effect>) async throws -> ToolOutput
}

extension Tool {
    public func runOutput(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> ToolOutput {
        .text(try await run(input: input, token: token))
    }

    /// The only direct tool entry point: derive the concrete effect, authorize
    /// it, and invoke the token-requiring implementation.
    public func run(input: Input, authority: any Authority) async throws -> String {
        let effect = try effect(for: input)
        return try await withEffect(effect, authority: authority) { token in
            try await run(input: input, token: token)
        }
    }

    public func runOutput(
        input: Input,
        authority: any Authority
    ) async throws -> ToolOutput {
        let effect = try effect(for: input)
        return try await withEffect(effect, authority: authority) { token in
            try await runOutput(input: input, token: token)
        }
    }

}

extension Tool {
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: Input.generationSchema)
    }
}

/// Type-erased tool. JSON remains the transport representation at the
/// provider boundary, while the actual argument conversion is performed by
/// `Input.init(_:)` from AnyLanguageModel's `GeneratedContent`.
public struct AnyTool: Sendable {
    public let name: String
    public let description: String
    public let schema: ToolDefinition
    /// Type erasure closes over the concrete effect type, so only this path
    /// can manufacture the matching token and invoke the tool.
    private let _runWithAuthority: @Sendable (ToolArguments, any Authority) async throws -> ToolOutput
    private let _runGeneratedWithAuthority: @Sendable (GeneratedContent, any Authority) async throws -> ToolOutput

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.schema = tool.schema
        self._runWithAuthority = { input, authority in
            let generated = try GeneratedContent(json: input.json)
            let decoded = try T.Input(generated)
            return try await tool.runOutput(input: decoded, authority: authority)
        }
        self._runGeneratedWithAuthority = { generated, authority in
            let decoded = try T.Input(generated)
            return try await tool.runOutput(input: decoded, authority: authority)
        }
    }

    public func run(input: ToolArguments, authority: any Authority) async throws -> String {
        try await _runWithAuthority(input, authority).transcript
    }

    public func runOutput(input: ToolArguments, authority: any Authority) async throws -> ToolOutput {
        try await _runWithAuthority(input, authority)
    }

    /// Executes arguments that have already been parsed by
    /// AnyLanguageModel. No provider JSON round-trip is needed here.
    public func run(
        generatedContent: GeneratedContent,
        authority: any Authority
    ) async throws -> String {
        try await _runGeneratedWithAuthority(generatedContent, authority).transcript
    }

    public func runOutput(
        generatedContent: GeneratedContent,
        authority: any Authority
    ) async throws -> ToolOutput {
        try await _runGeneratedWithAuthority(generatedContent, authority)
    }

}

public enum ToolError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String, value: String)
    case unauthorized(String)
    case notConfigured(String)
}
