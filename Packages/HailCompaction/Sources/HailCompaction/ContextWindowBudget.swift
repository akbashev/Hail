/// Maps a model name to its usable context window, in tokens.
///
/// The default is deliberately small: an Ollama server silently applies
/// `num_ctx = 4096` per request unless configured, whatever the model's
/// theoretical window is. Hosts that raised `num_ctx` (or run hosted models)
/// pass `overrides` — first matching substring wins, longest keys first.
public struct ContextWindowBudget: Sendable {
    /// Substring → window size, matched against the lowercased model name.
    public var overrides: [(String, Int)]
    /// The window assumed when nothing matches.
    public var defaultBudget: Int

    public init(overrides: [(String, Int)] = [], default defaultBudget: Int = 4096) {
        self.overrides = overrides.sorted { $0.0.count > $1.0.count }
        self.defaultBudget = defaultBudget
    }

    public func budget(for model: String) -> Int {
        let name = model.lowercased()
        for (key, budget) in overrides where name.contains(key.lowercased()) {
            return budget
        }
        for (key, budget) in Self.known where name.contains(key) {
            return budget
        }
        return defaultBudget
    }

    /// Widely deployed hosted windows. Local models are intentionally absent:
    /// their effective window is the server's, hence the conservative default.
    private static let known: [(String, Int)] = [
        ("claude", 200_000),
        ("gpt-4o", 128_000),
    ]
}
