#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A provider-facing reasoning effort identifier.
///
/// Effort names are intentionally open-ended: providers can add levels without
/// requiring a Hail release. The static values are convenience labels only;
/// support is declared per model by the host. A `nil` value on an agent
/// definition means that no override was requested and the provider/model
/// default should be used.
public struct ReasoningEffort: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    /// Creates a validated effort identifier.
    public init(_ rawValue: String) throws(ReasoningEffortError) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw .empty }
        self.rawValue = normalized
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    /// Explicitly requests no reasoning where the provider supports such a
    /// level. This is not the absence/default value; use `nil` to leave the
    /// provider's model-specific default untouched.
    public static let none = Self(uncheckedRawValue: "none")
    public static let minimal = Self(uncheckedRawValue: "minimal")
    public static let low = Self(uncheckedRawValue: "low")
    public static let medium = Self(uncheckedRawValue: "medium")
    public static let high = Self(uncheckedRawValue: "high")
    public static let xhigh = Self(uncheckedRawValue: "xhigh")
    public static let max = Self(uncheckedRawValue: "max")

    /// Creates a provider-specific level while retaining the same typed value.
    public static func custom(_ rawValue: String) throws(ReasoningEffortError) -> Self {
        try Self(rawValue)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ReasoningEffortError: Error, Sendable, Equatable {
    case empty
}

/// How a host wants a model adapter to represent a selected effort.
///
/// Most providers accept the effort identifier itself. Some APIs expose a
/// different control surface, such as Gemini's dynamic thinking or token
/// budget, so hosts can describe that translation without Hail guessing.
public enum ReasoningEffortEncoding: Codable, Sendable, Hashable {
    /// Send the effort's ``ReasoningEffort/rawValue`` unchanged.
    case raw
    /// Explicitly disable model reasoning.
    case disabled
    /// Let the provider choose a thinking budget dynamically.
    case dynamic
    /// Use a provider-specific thinking token budget.
    case tokenBudget(Int)
}

/// A requested effort together with the representation the endpoint should
/// use. The whole selection is optional at request boundaries; once present,
/// neither component can be missing.
public struct ReasoningEffortSelection: Codable, Sendable, Hashable {
    public let effort: ReasoningEffort
    public let encoding: ReasoningEffortEncoding

    public init(
        effort: ReasoningEffort,
        encoding: ReasoningEffortEncoding = .raw
    ) {
        self.effort = effort
        self.encoding = encoding
    }
}

/// A host-declared effort and its provider-facing representation.
public struct ModelReasoningLevel: Codable, Sendable, Hashable {
    public let effort: ReasoningEffort
    public let encoding: ReasoningEffortEncoding

    public init(
        effort: ReasoningEffort,
        encoding: ReasoningEffortEncoding = .raw
    ) {
        self.effort = effort
        self.encoding = encoding
    }
}

/// The reasoning levels a host has verified for one concrete model.
///
/// Hail keeps effort identifiers open-ended because providers can introduce
/// new names independently of Hail releases. This value describes a host's
/// knowledge about a model; it is not a universal claim about a provider.
public struct ModelReasoningCapabilities: Codable, Sendable, Hashable {
    public let levels: [ModelReasoningLevel]

    public var supportedEfforts: Set<ReasoningEffort> {
        Set(levels.map(\.effort))
    }

    public init(supportedEfforts: Set<ReasoningEffort> = []) {
        self.levels =
            supportedEfforts
            .sorted { $0.rawValue < $1.rawValue }
            .map { ModelReasoningLevel(effort: $0) }
    }

    public init(levels: [ModelReasoningLevel]) {
        self.levels = levels
    }

    public func supports(_ effort: ReasoningEffort) -> Bool {
        levels.contains { $0.effort == effort }
    }

    public func encoding(for effort: ReasoningEffort) -> ReasoningEffortEncoding? {
        levels.first { $0.effort == effort }?.encoding
    }
}
