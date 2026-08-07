/// The gate on ``Classified/reveal(_:)`` and ``Classified/init(sealing:access:)``.
///
/// The protocol is public so Hail modules can hold and pass access
/// values, but only the infrastructure layer creates conformers (their inits
/// are internal — see `SecretStore` in ProjectRuntime), so feature code
/// never holds a value that can unwrap a secret.
public protocol SecretAccess: Sendable {}

/// A secret value that can flow through the system without being able to
/// leak.
///
/// The wrapper makes the leak channels unrepresentable instead of
/// disciplined-against:
///
/// - It is deliberately **not `Codable`** — a secret can never be journaled,
///   serialized, or written into a config. Journals and configs carry
///   ``SecretRef`` instead.
/// - Its `description`/`debugDescription` are redacted, so printing,
///   interpolation, and logging can never expose the value.
/// - The raw value comes out only through ``reveal(_:)``, gated on
///   ``SecretAccess``.
public struct Classified<Wrapped: Sendable>: Sendable {
    private let value: Wrapped

    /// The module's own creation point. Cross-module sealing goes through
    /// ``init(sealing:access:)`` so it is gated the same way revealing is.
    init(_ value: Wrapped) {
        self.value = value
    }

    /// Seals a resolved secret value (e.g. a `SecretStore` handing a resolved
    /// ``SecretRef`` to an HTTP client). Gated on ``SecretAccess`` for the
    /// same reason ``reveal(_:)`` is: only the infrastructure layer moves raw
    /// secrets in and out of the wrapper.
    public init(sealing value: Wrapped, access: some SecretAccess) {
        self.init(value)
    }

    /// A transform of the wrapped secret that keeps the result classified:
    /// the value is handed to the closure inside the wrapper and the result
    /// stays wrapped. This is *not* a purity guarantee — `@Sendable` restricts
    /// what the closure captures, but it can still call ambient services
    /// (e.g. `URLSession.shared`) with the value it receives. What `map` does
    /// guarantee is that the transform's *result* stays classified and the
    /// closure never sees `self`'s description (always redacted).
    public func map<U: Sendable>(_ transform: @Sendable (Wrapped) -> U) -> Classified<U> {
        Classified<U>(transform(value))
    }

    /// The raw secret. Gated on ``SecretAccess``: only code holding an
    /// infrastructure-vended access value can unwrap.
    public func reveal(_ access: some SecretAccess) -> Wrapped {
        value
    }
}

extension Classified: CustomStringConvertible {
    public var description: String { "Classified(****)" }
}

extension Classified: CustomDebugStringConvertible {
    public var debugDescription: String { "Classified(****)" }
}
