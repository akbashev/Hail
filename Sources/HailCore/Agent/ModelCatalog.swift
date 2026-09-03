#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A model identifier is opaque to the domain, but typed so arbitrary strings
/// cannot be confused with IDs from another part of the configuration.
public struct AgentModelID: RawRepresentable, Codable, Sendable, Hashable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Suggested model names per provider, used by the UI to hint at known model
/// identifiers in the agent edit form.
///
/// The catalog is advisory only: ``ModelRouter`` passes any
/// `<provider>/<model-name>` identifier through to the provider verbatim, so
/// agents can always use model IDs that are not listed here. To surface new
/// model IDs without a code change, extend the catalog from the host's
/// configuration source.
public struct ModelCatalog: Codable, Sendable, Hashable {
    /// Provider → suggested model names, in display order. Both sides are
    /// domain values; arbitrary providers remain possible because
    /// ``AgentModelProvider`` is an open value type rather than an enum.
    public var suggestions: [AgentModelProvider: [AgentModelID]]

    public init(suggestions: [AgentModelProvider: [AgentModelID]]) {
        self.suggestions = suggestions
    }

    /// Decodes the configuration-facing object map at the boundary, then
    /// keeps provider identifiers typed in the domain value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: [AgentModelID]].self, forKey: .suggestions)
        self.suggestions = raw.reduce(into: [:]) { result, entry in
            result[AgentModelProvider(rawValue: entry.key)] = entry.value
        }
    }

    /// Encodes a configuration-facing object map without making the domain
    /// dictionary itself string-keyed.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let raw = suggestions.reduce(into: [String: [AgentModelID]]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        try container.encode(raw, forKey: .suggestions)
    }

    private enum CodingKeys: String, CodingKey {
        case suggestions
    }

    /// Returns a catalog that also suggests the given additional model names.
    /// Per provider the union is deduplicated, keeping built-in suggestions
    /// first and appending new ones in their given order.
    public func merged(with additions: [AgentModelProvider: [AgentModelID]]) -> ModelCatalog {
        var merged = suggestions
        for (provider, names) in additions {
            var seen = Set(merged[provider] ?? [])
            var combined = merged[provider] ?? []
            for name in names where seen.insert(name).inserted {
                combined.append(name)
            }
            merged[provider] = combined
        }
        return ModelCatalog(suggestions: merged)
    }

    /// Suggested model names for a provider, in display order.
    public func suggestions(for provider: AgentModelProvider) -> [AgentModelID] {
        suggestions[provider] ?? []
    }

    public func modelNames(for provider: AgentModelProvider) -> [String] {
        suggestions(for: provider).map(\.rawValue)
    }
}
