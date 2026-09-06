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

public protocol Tool<Input>: Sendable {
    associatedtype Input: Codable, Sendable
    associatedtype Effect: ScopedEffect

    var name: String { get }
    var description: String { get }
    var schema: LLMToolSchema { get }
    /// Pure: decoded model input to the concrete effect being requested.
    func effect(for input: Input) throws -> Effect

    /// Executes only after the registry has authorized the effect and vended
    /// its non-escapable token.
    func execute(input: Input, token: borrowing EffectToken<Effect>) async throws -> String

    func executeOutput(input: Input, token: borrowing EffectToken<Effect>) async throws -> ToolOutput
}

extension Tool {
    public func executeOutput(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> ToolOutput {
        .text(try await execute(input: input, token: token))
    }

    /// The only direct execution entry point: derive the concrete effect,
    /// authorize it, and invoke the token-requiring implementation.
    public func execute(input: Input, authority: any Authority) async throws -> String {
        let effect = try effect(for: input)
        return try await withEffect(effect, authority: authority) { token in
            try await execute(input: input, token: token)
        }
    }

    public func executeOutput(
        input: Input,
        authority: any Authority
    ) async throws -> ToolOutput {
        let effect = try effect(for: input)
        return try await withEffect(effect, authority: authority) { token in
            try await executeOutput(input: input, token: token)
        }
    }

}

/// Type-erased tool that accepts raw JSON arguments and decodes them directly
/// into the concrete tool's typed `Input` before execution.
public struct AnyTool: Sendable {
    public let name: String
    public let description: String
    public let schema: LLMToolSchema
    /// Type erasure closes over the concrete effect type, so only this path
    /// can manufacture the matching token and invoke the tool.
    private let _executeWithAuthority: @Sendable (ToolArguments, any Authority) async throws -> ToolOutput

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.schema = tool.schema
        self._executeWithAuthority = { input, authority in
            let decoded = try JSONDecoder().decode(T.Input.self, from: input.data)
            return try await tool.executeOutput(input: decoded, authority: authority)
        }
    }

    public func execute(input: ToolArguments, authority: any Authority) async throws -> String {
        try await _executeWithAuthority(input, authority).transcript
    }

    public func executeOutput(input: ToolArguments, authority: any Authority) async throws -> ToolOutput {
        try await _executeWithAuthority(input, authority)
    }
}

public enum ToolError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String, value: String)
    case unauthorized(String)
    case notConfigured(String)
}
