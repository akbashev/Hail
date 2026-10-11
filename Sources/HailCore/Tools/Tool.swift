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

/// A place as it is now: what the model reads there, and the tools it can call next. A call still
/// working shows one in its scope; a page at an address is opened by its host whenever it's shown.
public struct Page: Sendable {
    public var output: ToolOutput
    public var links: [any Tool]

    public init(_ output: ToolOutput, links: [any Tool] = []) {
        self.output = output
        self.links = links
    }

    public init(_ page: Page) {
        self = page
    }

    public static func text(_ text: String, links: [any Tool] = []) -> Page {
        Page(.text(text), links: links)
    }

    public static func data(_ data: ToolData, links: [any Tool] = []) -> Page {
        Page(.data(data), links: links)
    }

    /// The page as the model reads it: its content, then each available tool with its purpose.
    public var reading: String {
        let affordances = links.map { tool in
            let description = tool.description
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return description.isEmpty ? "- `\(tool.name)`" : "- `\(tool.name)`: \(description)"
        }
        return output.textRepresentation
            + (affordances.isEmpty ? "" : "\n\nNow you can use:\n" + affordances.joined(separator: "\n"))
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
        case page(PageAddress)
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

    public static func text(_ text: String, landing address: PageAddress) -> CallReturn {
        CallReturn(.text(text), next: .page(address))
    }

    /// A page shown as a result: its content, and its links.
    public init(_ page: Page) {
        self.init(page.output, next: .links(page.links))
    }
}

/// Where a page is: opaque to hail, which only stores it, compares it and hands it back. Only the
/// host that made it reads it.
public struct PageAddress: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Why a page can't be shown now.
public enum PageUnavailable: Error, Sendable, Equatable {
    /// It no longer exists: its tab closes.
    case gone
    /// It can't be reached now: its tab stays, and is shown again when it can be.
    case unreachable(String)
}

/// The host's pages: opens an address as the place is now.
public protocol Pages: Sendable {
    func open(_ address: PageAddress) async throws(PageUnavailable) -> Page
}

/// A host with no pages.
public struct NoPages: Pages {
    public init() {}

    public func open(_ address: PageAddress) async throws(PageUnavailable) -> Page {
        throw .gone
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
    func run(_ input: Input, in scope: borrowing ToolScope<Call>, token: borrowing EffectToken<Effect>) async throws -> CallReturn
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
public struct ToolGroup: Pages {
    public let name: String
    public let description: String
    public let tools: [any Tool]

    public init(name: String, description: String, tools: [any Tool]) {
        self.name = name
        self.description = description
        self.tools = tools
    }

    public var address: PageAddress { PageAddress(rawValue: name) }

    /// The link to it: its name, and the first sentence of what it's for. The rest is on its page.
    public var link: PageLink {
        PageLink(name: name, describedBy: description, address: address)
    }

    public func open(_ address: PageAddress) async throws(PageUnavailable) -> Page {
        guard address == self.address else { throw .gone }
        return Page(.text(description), links: tools)
    }

    /// Up to and including the first full stop that ends a sentence, or all of it.
    static func firstSentence(of text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }
}

/// Going to a page: the call lands on its address, and the session opens it as a tab, as it
/// opens any page a call lands on.
public struct PageEffect: ScopedEffect, Sendable {
    public let name = "pages.open"
    let address: PageAddress

    public init(address: PageAddress) {
        self.address = address
    }

    public static func run(in token: borrowing EffectToken<PageEffect>) async throws -> CallReturn {
        let address = token.withConfiguration { $0.address }
        return .text("Opened \(address).", landing: address)
    }
}

/// A link to a page, as a tool: calling it goes there, and the page shows what it's for and
/// links what can be done there. Arguments carried over from another tool are let be.
public struct PageLink: Tool {
    public typealias Input = GeneratedContent

    public let name: String
    public let description: String
    public let address: PageAddress

    public init(name: String, description: String, address: PageAddress) {
        self.name = name
        self.description = description
        self.address = address
    }

    /// A link that says what its page is for in the first sentence of `description`; the page
    /// says the rest.
    public init(name: String, describedBy description: String, address: PageAddress) {
        self.init(name: name, description: ToolGroup.firstSentence(of: description), address: address)
    }

    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: EmptyToolInput.generationSchema)
    }

    public func effect(for input: GeneratedContent) throws -> PageEffect { PageEffect(address: address) }

    public func run(_ input: GeneratedContent, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<PageEffect>) async throws
        -> CallReturn
    {
        try await PageEffect.run(in: token)
    }
}

/// Several hosts' pages as one: an address opens on the first that has it.
public struct CombinedPages: Pages {
    let pages: [any Pages]

    public init(_ pages: [any Pages]) {
        self.pages = pages
    }

    public func open(_ address: PageAddress) async throws(PageUnavailable) -> Page {
        for pages in pages {
            do {
                return try await pages.open(address)
            } catch {
                switch error {
                case .gone: continue
                case .unreachable: throw error
                }
            }
        }
        throw .gone
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
        self._call = { _, _, _ in throw ToolError.notConfigured("\(schema.name) is answered by the scope that offers it") }
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
        return try await call(generatedContent: generatedContent, authority: authority, origin: origin).resultWithoutModel()
    }

}

public enum ToolError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String, value: String)
    case unauthorized(String)
    case notConfigured(String)
}
