/// A scoped effect: an effect *configuration* whose live capability may only
/// be used inside a lexical scope opened by
/// ``withEffect(_:authority:isolation:operation:)``.
///
/// The effect value holds the configuration and dependencies as plain values
/// — it is data, not authority. Authority is the ``EffectToken`` vended
/// inside the scope: every operation on the effect requires one.
///
/// What the scope cannot decide statically it funnels: every activation
/// passes through one function — the single place a consumer's authority
/// layer can gate before a token exists.
public protocol ScopedEffect: Sendable {
    /// A stable name for diagnostics and authority decisions.
    var name: String { get }
}

/// The live capability for an ``ScopedEffect``, valid only inside the scope
/// that vended it.
///
/// - `~Escapable` — the token cannot be stored, returned, or captured by an
///   escaping closure (a `Task`, a `@Sendable` closure, another actor):
///   the capability dies with the scope's lexical extent.
/// - `~Sendable` — the token cannot cross an isolation boundary even where
///   escape analysis could be circumvented.
///
/// Operations on the effect are defined as extension methods on the token —
/// or take one as proof of scope — so no token, no effect:
///
/// ```swift
/// extension EffectToken where Effect == GreeterEffect {
///     func greet(_ who: String) -> String {
///         withConfiguration { "\($0.greeting), \(who)!" }
///     }
/// }
/// ```
public struct EffectToken<Effect: ScopedEffect>: ~Escapable, ~Sendable {
    private let effect: Effect

    @_lifetime(borrow effect)
    init(_ effect: borrowing Effect) {
        self.effect = copy effect
    }

    /// Accesses the effect's configuration from inside the scope. The
    /// configuration is `borrowing`: it can be read but cannot be extracted,
    /// so the token stays the only handle on the capability.
    public func withConfiguration<Result>(
        _ body: (borrowing Effect) throws -> Result
    ) rethrows -> Result {
        try body(effect)
    }
}
