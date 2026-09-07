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
public struct NowTool: Tool {
    public struct Input: Codable, Sendable {
        /// The IANA timezone in which the wall-clock reading is required.
        /// There is deliberately no default: a host must not silently use
        /// the server timezone for a user who may be elsewhere in the world.
        public let timeZone: TimeZone

        private enum CodingKeys: String, CodingKey {
            case timeZone = "time_zone"
        }

        public init(timeZone: TimeZone) {
            self.timeZone = timeZone
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let identifier = try container.decode(String.self, forKey: .timeZone)
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone,
                    in: container,
                    debugDescription: "Invalid IANA timezone: \(identifier)"
                )
            }
            self.timeZone = timeZone
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timeZone.identifier, forKey: .timeZone)
        }
    }

    public let name = "now"
    public let description =
        "Get the current time in an explicit IANA timezone. Always provide time_zone, for example Europe/Berlin. Never infer it from the server or from a message timestamp."

    public init() {}

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "time_zone": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Required IANA timezone, for example Europe/Berlin.",
                            enumValues: nil
                        )
                    ],
                    required: ["time_zone"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> ClockEffect {
        ClockEffect()
    }

    public func run(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> String {
        let instant = try await ClockEffect.run(in: token)
        let utc = instant.ISO8601Format()
        let timeZone = input.timeZone

        let local = instant.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .complete,
                locale: Locale(identifier: "en_GB"),
                timeZone: timeZone
            )
        )
        return "Local (\(timeZone.identifier)): \(local)\nUTC instant: \(utc)"
    }
}
