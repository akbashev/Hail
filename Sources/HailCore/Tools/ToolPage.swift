import AnyLanguageModel
import ScopedEffect

/// A place as it is now: what the model reads there, and the tools it can call next. A call still
/// working shows one in its scope; a page at an address is opened by its host whenever it's shown.
public struct ToolPage: Sendable {
    public var output: ToolOutput
    public var links: [any Tool]

    public init(_ output: ToolOutput, links: [any Tool] = []) {
        self.output = output
        self.links = links
    }

    public init(_ page: ToolPage) {
        self = page
    }

    public static func text(_ text: String, links: [any Tool] = []) -> ToolPage {
        ToolPage(.text(text), links: links)
    }

    public static func data(_ data: ToolData, links: [any Tool] = []) -> ToolPage {
        ToolPage(.data(data), links: links)
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

/// Where a page is: opaque to hail, which only stores it, compares it and hands it back. Only the
/// host that made it reads it.
public struct ToolPageAddress: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Why a page can't be shown now.
public enum ToolPageUnavailable: Error, Sendable, Equatable {
    /// It no longer exists: its tab closes.
    case gone
    /// It can't be reached now: its tab stays, and is shown again when it can be.
    case unreachable(String)
}

/// The host's pages: opens an address as the place is now.
public protocol ToolPages: Sendable {
    func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage
}

/// A host with no pages.
public struct NoToolPages: ToolPages {
    public init() {}

    public func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
        throw .gone
    }
}

/// Going to a page: the call lands on its address, and the session opens it as a tab, as it
/// opens any page a call lands on.
public struct ToolPageEffect: ScopedEffect, Sendable {
    public let name = "pages.open"
    let address: ToolPageAddress

    public init(address: ToolPageAddress) {
        self.address = address
    }

    public static func run(in token: borrowing EffectToken<ToolPageEffect>) async throws -> CallReturn {
        let address = token.withConfiguration { $0.address }
        return .text("Opened \(address).", landing: address)
    }
}

/// A link to a page, as a tool: calling it goes there, and the page shows what it's for and
/// links what can be done there. Arguments carried over from another tool are let be.
public struct ToolPageLink: Tool {
    public typealias Input = GeneratedContent

    public let name: String
    public let description: String
    public let address: ToolPageAddress

    public init(name: String, description: String, address: ToolPageAddress) {
        self.name = name
        self.description = description
        self.address = address
    }

    /// A link that says what its page is for in the first sentence of `description`; the page
    /// says the rest.
    public init(name: String, describedBy description: String, address: ToolPageAddress) {
        self.init(name: name, description: ToolGroup.firstSentence(of: description), address: address)
    }

    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: EmptyToolInput.generationSchema)
    }

    public func effect(for input: GeneratedContent) throws -> ToolPageEffect { ToolPageEffect(address: address) }

    public func run(_ input: GeneratedContent, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ToolPageEffect>) async throws
        -> CallReturn
    {
        try await ToolPageEffect.run(in: token)
    }
}

/// Several hosts' pages as one: an address opens on the first that has it.
public struct CombinedToolPages: ToolPages {
    let pages: [any ToolPages]

    public init(_ pages: [any ToolPages]) {
        self.pages = pages
    }

    public func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
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

/// A tool's failure with a page of its own: what went wrong, and the tools to recover with, such
/// as the object that already exists.
public struct ToolPageError: Error, Sendable {
    public let page: ToolPage
    public let kind: ToolFailureKind

    public init(_ page: ToolPage, kind: ToolFailureKind = .failed) {
        self.page = page
        self.kind = kind
    }
}
