#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    public var suggestions: [String: [String]]

    public init(suggestions: [String: [String]]) {
        self.suggestions = suggestions
    }

    /// Built-in suggestions: the Kimi Code model tiers plus current models for
    /// the other providers (each provider's ``ModelRouter`` fallback for an
    /// empty model name is always included).
    public static let `default` = ModelCatalog(suggestions: [
        "kimi-code": ["k3", "kimi-for-coding", "kimi-for-coding-highspeed"],
        "claude": ["opus", "sonnet", "haiku", "fable"],
        "moonshot": ["kimi-k2.5"],
        "openai": ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4-mini"],
        "anthropic": ["claude-sonnet-4-20250514"],
        "gemini": ["gemini-2.5-pro"],
        "ollama": ["qwen2.5"],
        // Codex CLI's current recommended family plus currently supported
        // previous-generation models. `gpt-5.6` is the CLI alias for Sol;
        // Spark is a Pro-only preview model. GPT-5.4 and GPT-5.4 mini remain
        // available until their announced August 31, 2026 retirement for
        // ChatGPT-authenticated Codex sessions.
        "codex": [
            "gpt-5.6",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.3-codex-spark",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ],
    ])

    /// Returns a catalog that also suggests the given additional model names.
    /// Per provider the union is deduplicated, keeping built-in suggestions
    /// first and appending new ones in their given order.
    public func merged(with additions: [String: [String]]) -> ModelCatalog {
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
    public func suggestions(for provider: String) -> [String] {
        suggestions[provider] ?? []
    }
}
