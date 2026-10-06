import AnyLanguageModel
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Raw content produced by a tool. It preserves transport data and metadata;
/// interpreting the MIME type belongs to the model adapter.
public struct ToolData: Codable, Sendable, Equatable {
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

public enum ToolOutput: Codable, Sendable, Equatable {
    case text(String)
    case data(ToolData)

    /// A presentation projection for adapters that can only display text.
    /// The typed value remains available through ``ToolOutput`` itself.
    public var textRepresentation: String {
        switch self {
        case .text(let text):
            return text
        case .data(let data):
            let source = data.source.map { " from \($0.absoluteString)" } ?? ""
            let type = data.normalizedContentType
            return "Fetched \(data.body.count) bytes\(source) with content type \(type)."
        }
    }

    /// Converts the typed result into the model transcript representation.
    /// Raw data stays typed in the journal; only providers that cannot carry a
    /// particular media type receive its explicit textual description.
    public var transcriptSegments: [Transcript.Segment] {
        switch self {
        case .text(let text):
            return [.text(.init(content: text))]

        case .data(let data):
            if data.isTextLike {
                return [.text(.init(content: String(decoding: data.body, as: UTF8.self)))]
            }
            if data.normalizedContentType.hasPrefix("image/") {
                return [
                    .text(.init(content: textRepresentation)),
                    .image(.init(data: data.body, mimeType: data.normalizedContentType)),
                ]
            }
            return [.text(.init(content: textRepresentation))]
        }
    }

    /// The representation accepted by AnyLanguageModel's tool-output
    /// boundary. Text and textual data remain generated content; opaque
    /// binary data is rejected instead of being silently replaced with a
    /// description that the model could mistake for the actual result.
    public func modelContent() throws -> GeneratedContent {
        switch self {
        case .text(let text):
            return GeneratedContent(text)
        case .data(let data):
            guard data.isTextLike else {
                throw ToolOutputError.binaryDataNotRepresentable
            }
            return try GeneratedContent(
                json: String(decoding: data.body, as: UTF8.self)
            )
        }
    }
}

public enum ToolOutputError: Error, Equatable, Sendable {
    case binaryDataNotRepresentable
}

/// The model input for a tool command that takes no arguments.
public struct EmptyToolInput: Generable, Sendable {
    public init() {}

    public init(_ content: GeneratedContent) throws {
        guard case .structure(let properties, _) = content.kind,
            properties.isEmpty
        else {
            throw GeneratedContentError.typeMismatch
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
    /// An optional tool-owned restriction. The host intersects it with the
    /// lane authority before minting any effect token. Tools never receive
    /// the lane authority itself and therefore cannot widen it.
    var authorityRestriction: (any Authority)? { get }
    /// Pure: decoded model input to the concrete effect being requested.
    func effect(for input: Input) throws -> Effect

    /// Runs only after the registry has authorized the effect and vended its
    /// non-escapable token. The typed ToolOutput is the authoritative result;
    /// text is one possible provider representation, not the tool contract.
    func runOutput(input: Input, token: borrowing EffectToken<Effect>) async throws -> ToolOutput
}

extension Tool {
    public var authorityRestriction: (any Authority)? { nil }

    /// The only direct tool entry point: derive the concrete effect, authorize
    /// it, and invoke the token-requiring implementation.
    public func runOutput(input: Input, authority: any Authority) async throws -> ToolOutput {
        let effect = try effect(for: input)
        let effectiveAuthority: any Authority
        if let restriction = authorityRestriction {
            effectiveAuthority = IntersectingAuthority([authority, restriction])
        } else {
            effectiveAuthority = authority
        }
        return try await withEffect(effect, authority: effectiveAuthority) { token in
            try await runOutput(input: input, token: token)
        }
    }
}

extension Tool {
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: Input.generationSchema)
    }
}

/// Type-erased tool. Arguments remain AnyLanguageModel's generated value all
/// the way from the provider boundary to typed `Input` decoding; there is no
/// intermediate JSON-string representation in Hail's execution path.
public struct AnyTool: Sendable {
    public let name: String
    public let description: String
    public let schema: ToolDefinition
    /// Type erasure closes over the concrete effect type, so only this path
    /// can manufacture the matching token and invoke the tool.
    private let _runGeneratedWithAuthority: @Sendable (GeneratedContent, any Authority) async throws -> ToolOutput

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.schema = tool.schema
        self._runGeneratedWithAuthority = { generated, authority in
            let decoded: T.Input
            decoded = try T.Input(leniently: generated)
            return try await tool.runOutput(input: decoded, authority: authority)
        }
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
