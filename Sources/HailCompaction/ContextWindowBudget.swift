/// Maps a model name to its usable context window, in tokens.
///
/// The default is deliberately conservative: an Ollama server commonly uses
/// `num_ctx = 4096` per request unless configured. Hosts pass explicit
/// overrides for other effective windows — first matching substring wins,
/// longest keys first. Endpoint-provided limits take precedence at runtime.
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
        return defaultBudget
    }
}
