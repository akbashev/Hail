import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Gives an agent the wall-clock time at the moment the tool is called.
///
/// The clock is injected so the tool remains deterministic and cheap to test;
/// production instances use the system clock. The result is ISO 8601, which
/// is unambiguous across model providers and time zones.
public struct NowTool: Tool {
    public struct Input: Codable, Sendable {
        public init() {}
    }

    public let name = "now"
    public let description = "Get the current date and time as an ISO 8601 timestamp."

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [:],
                    required: []
                )
            )
        )
    }

    public func effect(for input: Input) throws -> ClockEffect {
        ClockEffect()
    }

    public func execute(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> String {
        _ = token
        return clock().ISO8601Format()
    }
}
