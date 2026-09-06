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

/// An effect whose authority is determined by its component effects.
///
/// Composite effects are useful when one operation needs several capabilities
/// at once. The component values remain ordinary ``ScopedEffect`` values, so
/// existing per-domain authority policies continue to apply. A composite
/// effect does not introduce a new authority domain of its own.
public protocol CompositeScopedEffect: ScopedEffect {
    func decision(using authority: any Authority) -> EffectDecision
}

/// The product of two effect requirements.
///
/// Composition is intentionally binary. Repeated composition gives us an
/// arbitrary, statically typed effect tree without requiring heterogeneous
/// collections or a variadic-generic public API:
///
/// ```swift
/// let requirements = clock
///     .combined(with: scheduler)
///     .combined(with: weather)
///     .combined(with: fetch)
/// ```
public struct CombinedEffect<Left: ScopedEffect, Right: ScopedEffect>:
    CompositeScopedEffect,
    Sendable
{
    public let left: Left
    public let right: Right

    public var name: String {
        "\(left.name)+\(right.name)"
    }

    public init(left: Left, right: Right) {
        self.left = left
        self.right = right
    }

    public func decision(using authority: any Authority) -> EffectDecision {
        let decisions = [
            (left.name, authority.decision(on: left)),
            (right.name, authority.decision(on: right)),
        ]

        let denials = decisions.compactMap { name, decision -> String? in
            guard case .denied(let reason) = decision else { return nil }
            return "\(name): \(reason)"
        }

        return denials.isEmpty
            ? .granted
            : .denied(denials.joined(separator: "; "))
    }
}

extension ScopedEffect {
    /// Combines this effect requirement with another one.
    public func combined<Other: ScopedEffect>(
        with other: Other
    ) -> CombinedEffect<Self, Other> {
        CombinedEffect(left: self, right: other)
    }
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

extension EffectToken {
    /// Re-enters the left capability contained by a combined effect.
    ///
    /// The child token is minted only inside the parent token's lexical scope;
    /// it cannot outlive this operation or cross an isolation boundary.
    public func withLeft<Left: ScopedEffect, Right: ScopedEffect, Result>(
        _ operation: (borrowing EffectToken<Left>) async throws -> Result
    ) async rethrows -> Result where Effect == CombinedEffect<Left, Right> {
        let left = withConfiguration { $0.left }
        return try await _withEffectUnchecked(left, operation: operation)
    }

    /// Re-enters the right capability contained by a combined effect.
    public func withRight<Left: ScopedEffect, Right: ScopedEffect, Result>(
        _ operation: (borrowing EffectToken<Right>) async throws -> Result
    ) async rethrows -> Result where Effect == CombinedEffect<Left, Right> {
        let right = withConfiguration { $0.right }
        return try await _withEffectUnchecked(right, operation: operation)
    }
}
