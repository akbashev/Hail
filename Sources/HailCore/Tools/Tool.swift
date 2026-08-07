import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
}

extension Tool {
    /// The only direct execution entry point: derive the concrete effect,
    /// authorize it, and invoke the token-requiring implementation.
    public func execute(input: Input, authority: any Authority) async throws -> String {
        let effect = try effect(for: input)
        return try await withEffect(effect, authority: authority) { token in
            try await execute(input: input, token: token)
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
    private let _executeWithAuthority: @Sendable (ToolArguments, any Authority) async throws -> String

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.schema = tool.schema
        self._executeWithAuthority = { input, authority in
            let decoded = try JSONDecoder().decode(T.Input.self, from: input.data)
            return try await tool.execute(input: decoded, authority: authority)
        }
    }

    public func execute(input: ToolArguments, authority: any Authority) async throws -> String {
        try await _executeWithAuthority(input, authority)
    }
}

public enum ToolError: Error, Sendable {
    case missingArgument(String)
    case invalidArgument(String, value: String)
    case unauthorized(String)
    case notConfigured(String)
}
