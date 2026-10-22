import AnyLanguageModel
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Gives an agent the wall-clock time at the moment the tool is called.
///
/// The instant is supplied by the scoped clock capability. It is always
/// returned in UTC, while the configured IANA timezone is rendered separately
/// for wall-clock operations such as reminders and schedules. A `Date` has no
/// timezone of its own, so the two representations must not be collapsed into
/// one model-facing string.
@Tool(
    "now",
    description:
        "Get the current time in an explicit IANA timezone. Always provide time_zone, for example Europe/Berlin. Never infer it from the server or from a message timestamp."
)
public struct NowTool {
    public init() {}

    public var schema: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: NowToolInput.generationSchema
        )
    }

    public func effect(for input: NowToolInput) throws -> ClockEffect {
        ClockEffect()
    }

    public func run(
        _ input: NowToolInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>
    ) async throws -> CallReturn {
        let instant = try await ClockEffect.run(in: token)
        let utc = instant.ISO8601Format()
        guard let timeZone = TimeZone(identifier: input.timeZone) else {
            throw ToolError.invalidArgument("time_zone", value: input.timeZone)
        }

        let local = instant.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .complete,
                locale: Locale(identifier: "en_GB"),
                timeZone: timeZone
            )
        )
        return .text("Local (\(timeZone.identifier)): \(local)\nUTC instant: \(utc)")
    }
}

// Formerly NowTool.Input; renamed during the no-nested-Generable sweep.
@Generable
public struct NowToolInput: Sendable {
    /// The IANA timezone in which the wall-clock reading is required.
    /// There is deliberately no default: a host must not silently use
    /// the server timezone for a user who may be elsewhere in the world.
    /// It is a string at the model boundary because `TimeZone` is a
    /// runtime Foundation value; the tool validates it before use.
    public let timeZone: String

}
