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
/// model IDs without a code change, extend the catalog from
/// `.hail/config.yaml` (`models:` section) — see
/// ``HailConfiguration/modelCatalog``.
public struct ModelCatalog: Codable, Sendable, Hashable {
    /// Provider name → suggested model names, in display order.
    /// Provider names are strings because they are configuration keys; model
    /// values themselves remain typed IDs.
    public var suggestions: [String: [AgentModelID]]

    public init(suggestions: [String: [AgentModelID]]) {
        self.suggestions = suggestions
    }

    public init(suggestions: [String: [String]]) {
        self.suggestions = suggestions.mapValues { $0.map(AgentModelID.init(rawValue:)) }
    }

    /// Returns a catalog that also suggests the given additional model names.
    /// Per provider the union is deduplicated, keeping built-in suggestions
    /// first and appending new ones in their given order.
    public func merged(with additions: [String: [AgentModelID]]) -> ModelCatalog {
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

    public func merged(with additions: [String: [String]]) -> ModelCatalog {
        merged(with: additions.mapValues { $0.map(AgentModelID.init(rawValue:)) })
    }

    /// Suggested model names for a provider, in display order.
    public func suggestions(for provider: String) -> [AgentModelID] {
        suggestions[provider] ?? []
    }

    public func modelNames(for provider: String) -> [String] {
        suggestions(for: provider).map(\.rawValue)
    }
}
