/// A *reference* to a secret — the only secret-shaped value allowed in
/// journals, configs, and the UI.
///
/// The value itself never appears here: `.env(name)` points at a process
/// environment variable, `.store(id)` at a `SecretStore` entry. Resolution
/// happens at the edge that needs the secret (yielding a ``Classified``), so
/// the durable record stays safe to commit, replay, and render.
public enum SecretRef: Codable, Sendable, Equatable {
    /// A process environment variable name (e.g. `"OPENAI_API_KEY"`).
    case env(String)
    /// A `SecretStore` entry id — a plain filename in the store's directory.
    case store(String)
}
