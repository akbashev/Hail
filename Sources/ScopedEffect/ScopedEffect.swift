/// A scoped effect is inert configuration. Its operation is available only
/// after an authority has opened a matching ``EffectToken``.
public protocol ScopedEffect: Sendable {
    associatedtype Output: Sendable = Void

    /// A stable name for diagnostics and authority decisions.
    var name: String { get }

    /// Runs an already-authorized effect token.
    ///
    /// The configuration comes from the exact token, rather than from an
    /// unrelated effect value paired with a token for another value.
    static func run(
        in token: borrowing EffectToken<Self>
    ) async throws -> Output
}

/// An effect whose authority is determined by its component effects.
///
/// The component values remain ordinary ``ScopedEffect`` values, so
/// existing per-domain authority policies continue to apply. A composite
/// effect does not introduce a new authority domain of its own.
public protocol CompositeScopedEffect: ScopedEffect {
    /// The static child effects this operation is built from. Declaring the
    /// list is the composition: the default ``decision(using:)`` derives
    /// from it, and readers can see the dependency graph before anything
    /// runs. Children spawned dynamically inside ``run`` are not listed;
    /// they are checked against the same authority at spawn time.
    var childEffects: [any ScopedEffect] { get }

    func decision(using authority: any Authority) -> EffectDecision
}

extension CompositeScopedEffect {
    /// Grants only when every declared child effect is granted; denials name the refusing
    /// children, and keep what each refused.
    public func decision(using authority: any Authority) -> EffectDecision {
        let denials = childEffects.compactMap { child -> EffectRefusal? in
            guard case .denied(let refusal) = authority.decision(on: child) else { return nil }
            return EffectRefusal("\(child.name): \(refusal.reason)", refused: refusal.refused)
        }
        return denials.isEmpty ? .granted : .denied(.joined(denials))
    }
}

/// The result of running a binary effect composition in sequence.
public struct CombinedEffectResult<Left: Sendable, Right: Sendable>: Sendable {
    public let left: Left
    public let right: Right

    public init(left: Left, right: Right) {
        self.left = left
        self.right = right
    }
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
    public typealias Output = CombinedEffectResult<Left.Output, Right.Output>

    public let left: Left
    public let right: Right

    public var name: String {
        "\(left.name)+\(right.name)"
    }

    public var childEffects: [any ScopedEffect] {
        [left, right]
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

        let denials = decisions.compactMap { name, decision -> EffectRefusal? in
            guard case .denied(let refusal) = decision else { return nil }
            return EffectRefusal("\(name): \(refusal.reason)", refused: refusal.refused)
        }

        return denials.isEmpty ? .granted : .denied(.joined(denials))
    }

    public static func run(
        in token: borrowing EffectToken<CombinedEffect<Left, Right>>
    ) async throws -> Output {
        let left = try await token.withLeft { leftToken in
            try await Left.run(in: leftToken)
        }
        let right = try await token.withRight { rightToken in
            try await Right.run(in: rightToken)
        }
        return Output(left: left, right: right)
    }

}

extension ScopedEffect {
    /// Composes this effect inside an already-open parent token. The parent
    /// authority is checked against this concrete effect before its exact
    /// child token is created.
    public func combined<Other: ScopedEffect>(
        with other: Other
    ) -> CombinedEffect<Self, Other> {
        CombinedEffect(left: self, right: other)
    }
}

extension ScopedEffect {
    public func run<Parent: ScopedEffect>(
        in token: borrowing EffectToken<Parent>
    ) async throws -> Output {
        try await token.run(self)
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
    private let authority: any Authority

    @_lifetime(borrow effect)
    init(
        _ effect: borrowing Effect,
        authority: any Authority
    ) {
        self.effect = copy effect
        self.authority = authority
    }

    /// Accesses inert effect configuration from inside the token.
    ///
    /// Effect configuration may be copied. It must therefore contain data
    /// only, never a live client or an authority-bearing closure. Execution
    /// remains available through `run`.
    public func withConfiguration<Result>(
        _ body: (borrowing Effect) throws -> Result
    ) rethrows -> Result {
        try body(effect)
    }

    /// Opens and runs a child effect after checking the same authority against
    /// that concrete child value.
    public func run<Child: ScopedEffect>(
        _ child: Child
    ) async throws -> Child.Output {
        try await withChild(child) { childToken in
            try await Child.run(in: childToken)
        }
    }

    /// Opens a child token for composed operations that need more than the
    /// child's output.
    public func withChild<Child: ScopedEffect, Result>(
        _ child: Child,
        operation: (borrowing EffectToken<Child>) async throws -> Result
    ) async throws -> Result {
        let decision = authority.decision(on: child)
        EffectAudit.record(child, decision)
        switch decision {
        case .granted:
            return try await _withEffectUnchecked(
                child,
                authority: authority,
                operation: operation
            )
        case .denied(let refusal):
            throw EffectDenied(effect: child.name, refusal: refusal)
        }
    }
}

extension EffectToken {
    /// Re-enters the left capability contained by a combined effect.
    ///
    /// The child token is minted only inside the parent token's lexical scope;
    /// it cannot outlive this operation or cross an isolation boundary.
    public func withLeft<Left: ScopedEffect, Right: ScopedEffect, Result>(
        _ operation: (borrowing EffectToken<Left>) async throws -> Result
    ) async throws -> Result where Effect == CombinedEffect<Left, Right> {
        let left = withConfiguration { $0.left }
        return try await withChild(left, operation: operation)
    }

    /// Re-enters the right capability contained by a combined effect.
    public func withRight<Left: ScopedEffect, Right: ScopedEffect, Result>(
        _ operation: (borrowing EffectToken<Right>) async throws -> Result
    ) async throws -> Result where Effect == CombinedEffect<Left, Right> {
        let right = withConfiguration { $0.right }
        return try await withChild(right, operation: operation)
    }
}
