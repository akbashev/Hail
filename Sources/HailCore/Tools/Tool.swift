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

/// What a call gives back: what it did, and what comes next: the tools it links to, or the page it
/// landed on. The result is kept in the agent's history; a page never is, only its address.
public struct CallReturn: Sendable {
    public let result: ToolOutput
    public let next: Next

    public enum Next: Sendable {
        /// Tools the model can call next, offered beside the result.
        case links([any Tool])
        /// The page the call landed on: opened by its host, now and whenever its tab is shown.
        case page(ToolPageAddress)
    }

    public init(_ result: ToolOutput, next: Next = .links([])) {
        self.result = result
        self.next = next
    }

    public static func text(_ text: String, links: [any Tool] = []) -> CallReturn {
        CallReturn(.text(text), next: .links(links))
    }

    public static func data(_ data: ToolData, links: [any Tool] = []) -> CallReturn {
        CallReturn(.data(data), next: .links(links))
    }

    public static func text(_ text: String, landing address: ToolPageAddress) -> CallReturn {
        CallReturn(.text(text), next: .page(address))
    }

    /// A page shown as a result: its content, and its links.
    public init(_ page: ToolPage) {
        self.init(page.output, next: .links(page.links))
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
    /// What the model's calls inside its scope are, for a tool that offers tools of its own while
    /// it works; `Never` for one that has its result at once.
    associatedtype Call: Sendable = Never

    var name: String { get }
    var description: String { get }
    var schema: ToolDefinition { get }
    /// An optional tool-owned restriction. The host intersects it with the
    /// lane authority before minting any effect token. Tools never receive
    /// the lane authority itself and therefore cannot widen it.
    var authorityRestriction: (any Authority)? { get }
    /// Pure: decoded model input to the concrete effect being requested.
    func effect(for input: Input) throws -> Effect

    /// Runs the call in its scope, only after the registry has authorized the effect and vended
    /// its non-escapable token. A tool that has its result at once returns it; one that needs
    /// more from the model shows it pages in `scope` and answers its calls there, then returns.
    /// What it returns is what the call did, and what comes next: links, or the page it landed on.
    func run(_ input: Input, in scope: borrowing ToolScope<Call>, token: borrowing EffectToken<Effect>) async throws
        -> CallReturn
}

extension Tool {
    public var authorityRestriction: (any Authority)? { nil }

    /// The authority its effects are checked against: the lane's, narrowed by its own restriction.
    func effective(_ authority: any Authority) -> any Authority {
        authorityRestriction.map { IntersectingAuthority([authority, $0]) } ?? authority
    }

    /// Runs a call with no model to work with: its result, or the first page its scope shows.
    public func runOutput(input: Input, authority: any Authority) async throws -> CallReturn {
        let origin = Origin.direct(ToolCall(id: UUID().uuidString, name: name, arguments: input.generatedContent))
        return try await call(self, input, authority: authority, origin: origin).resultWithoutModel()
    }
}

extension Tool {
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: Input.generationSchema)
    }
}

/// Tools that belong together, such as the weather's current, hourly and daily: a `@Tool` with
/// commands, or tools a host gathers. A group is a page: what it's for is its text, its tools are
/// its links, and a link to it is what the model starts from.
public struct ToolGroup: ToolPages {
    public let name: String
    public let description: String
    public let tools: [any Tool]

    public init(name: String, description: String, tools: [any Tool]) {
        self.name = name
        self.description = description
        self.tools = tools
    }

    public var address: ToolPageAddress { ToolPageAddress(rawValue: name) }

    /// The link to it: its name, and the first sentence of what it's for. The rest is on its page.
    public var link: ToolPageLink {
        ToolPageLink(name: name, describedBy: description, address: address)
    }

    public func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
        guard address == self.address else { throw .gone }
        return ToolPage(.text(description), links: tools)
    }

    /// Up to and including the first full stop that ends a sentence, or all of it.
    static func firstSentence(of text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
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
    private let _call: @Sendable (GeneratedContent, any Authority, Origin) throws -> RunningCall

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.schema = tool.schema
        self._call = { generated, authority, origin in
            try HailCore.call(tool, try T.Input(leniently: generated), authority: authority, origin: origin)
        }
    }

    /// A tool a scope offers, as the model sees it: the scope answers its calls, so it never
    /// starts one of its own.
    init(offered schema: ToolDefinition) {
        self.name = schema.name
        self.description = schema.description
        self.schema = schema
        self._call = { _, _, _ in
            throw ToolError.notConfigured("\(schema.name) is answered by the scope that offers it")
        }
    }

    /// Calls it in a scope of its own: the running call the caller talks to it through.
    func call(generatedContent: GeneratedContent, authority: any Authority, origin: Origin) throws -> RunningCall {
        try _call(generatedContent, authority, origin)
    }

    /// Runs a call with no model to work with: its result, or the first page its scope shows.
    public func runOutput(
        generatedContent: GeneratedContent,
        authority: any Authority
    ) async throws -> CallReturn {
        let origin = Origin.direct(ToolCall(id: UUID().uuidString, name: name, arguments: generatedContent))
        return try await call(generatedContent: generatedContent, authority: authority, origin: origin)
            .resultWithoutModel()
    }

}

public enum ToolError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String, value: String)
    case unauthorized(String)
    case notConfigured(String)
}
