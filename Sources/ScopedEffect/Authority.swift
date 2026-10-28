/// The authority layer for scoped effects: who may activate which effect,
/// decided as a value before any capability exists. Built on this module's
/// public scope function —
/// ``withEffect(_:authority:isolation:operation:)`` below is the composition
/// point, the only thing that knows both concepts.
import Synchronization

/// A pure decision over one effect configuration: granted, denied, or one the authority can't
/// make from what it holds, which only an answer to asking gives.
public enum EffectDecision: Sendable, Equatable {
    case granted
    case denied(String)
    /// It has to be asked: ``Authority/ask(about:)`` gives the answer.
    case needs
}

/// What an authority answers, asked about an activation its decision said needs asking.
public enum EffectAnswer: Sendable, Equatable {
    case granted
    case denied(String)

    /// The answer as the decision it comes to.
    public var decision: EffectDecision {
        switch self {
        case .granted: .granted
        case .denied(let reason): .denied(reason)
        }
    }
}

/// The full authority of one execution lane: which effects it may activate.
///
/// An authority is a value, derived once per activation (or lane, or spawn)
/// by a pure function of the caller's identity and execution context. Every
/// effect activation in that lane is checked against it, so
/// "what may this lane do" is a short, reviewable value rather than a
/// discipline spread across call sites.
///
/// Authority is deny-by-default: the default implementation grants nothing.
public protocol Authority: Sendable {
    /// The decision for one concrete effect activation.
    func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision

    /// The answer for an activation whose decision ``EffectDecision/needs`` it: asked of whoever
    /// gives it, and waited for.
    func ask<Effect: ScopedEffect>(about effect: Effect) async -> EffectAnswer
}

extension Authority {
    /// Deny-by-default: an authority that decides nothing decides denial.
    public func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        .denied("the '\(effect.name)' effect is not granted by this authority")
    }

    /// An authority that decides everything itself has no one to ask: no answer is a denial.
    public func ask<Effect: ScopedEffect>(about effect: Effect) async -> EffectAnswer {
        .denied("the '\(effect.name)' effect is not granted by this authority")
    }
}

/// The wide-open authority: every effect is granted unconditionally. The
/// explicit "no restrictions" value a lane starts from before a narrower
/// authority is derived for it.
public struct FullAuthority: Authority {
    public init() {}

    public func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        .granted
    }
}

/// An authority that requires every member authority to grant an effect.
///
/// This is useful when a broad host/lane policy must be narrowed by a more
/// specific policy, such as a workflow or tool policy. A narrower authority
/// can never widen the permissions of the authorities it is intersected with.
public struct IntersectingAuthority: Authority {
    public let authorities: [any Authority]

    public init(_ authorities: [any Authority]) {
        self.authorities = authorities
    }

    public func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        var denials: [String] = []
        var needs = false
        for authority in authorities {
            switch authority.decision(on: effect) {
            case .granted: break
            case .denied(let reason): denials.append(reason)
            case .needs: needs = true
            }
        }
        if !denials.isEmpty { return .denied(denials.joined(separator: "; ")) }
        return needs ? .needs : .granted
    }

    /// Asks each member whose decision needs asking: granted only when every one of them grants.
    public func ask<Effect: ScopedEffect>(about effect: Effect) async -> EffectAnswer {
        var denials: [String] = []
        for authority in authorities where authority.decision(on: effect) == .needs {
            if case .denied(let reason) = await authority.ask(about: effect) {
                denials.append(reason)
            }
        }
        return denials.isEmpty ? .granted : .denied(denials.joined(separator: "; "))
    }
}

/// An authority assembled from per-domain decision closures, as a value.
///
/// ```swift
/// let authority = CompositeAuthority()
///     .granting(for: FileEffect.self, decide: FileEffect.pathPolicy(scopedTo: workspace))
///     .grantingAll(for: NetworkEffect.self)
/// // TerminalEffect is not mentioned: closed (deny-by-default).
/// ```
public struct CompositeAuthority: Authority {
    /// Decision closures keyed by domain. Type-erased at rest, re-typed on
    /// lookup by the generic cast.
    private var decisions: [ObjectIdentifier: @Sendable (any ScopedEffect) -> EffectDecision]
    /// Who answers, by domain, for what its decision says needs asking.
    private var answers: [ObjectIdentifier: @Sendable (any ScopedEffect) async -> EffectAnswer]

    public init() {
        decisions = [:]
        answers = [:]
    }

    /// Returns a copy with `decide` installed for `domain`.
    public func granting<Effect: ScopedEffect>(
        for domain: Effect.Type,
        decide: @escaping @Sendable (Effect) -> EffectDecision
    ) -> CompositeAuthority {
        var copy = self
        copy.decisions[ObjectIdentifier(domain)] = { effect in
            guard let typed = effect as? Effect else {
                return .denied("the '\(effect.name)' effect is not granted by this authority")
            }
            return decide(typed)
        }
        return copy
    }

    /// Returns a copy with `decide` installed for `domain`, and `ask` giving the answer for what
    /// `decide` says needs asking.
    public func granting<Effect: ScopedEffect>(
        for domain: Effect.Type,
        decide: @escaping @Sendable (Effect) -> EffectDecision,
        ask: @escaping @Sendable (Effect) async -> EffectAnswer
    ) -> CompositeAuthority {
        var copy = granting(for: domain, decide: decide)
        copy.answers[ObjectIdentifier(domain)] = { effect in
            guard let typed = effect as? Effect else {
                return .denied("the '\(effect.name)' effect is not granted by this authority")
            }
            return await ask(typed)
        }
        return copy
    }

    /// Returns a copy with `domain` unconditionally granted.
    public func grantingAll<Effect: ScopedEffect>(for domain: Effect.Type) -> CompositeAuthority {
        granting(for: domain) { _ in .granted }
    }

    public func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        if let composite = effect as? any CompositeScopedEffect {
            return composite.decision(using: self)
        }

        guard let decide = decisions[ObjectIdentifier(Effect.self)] else {
            return .denied("the '\(effect.name)' effect is not granted by this authority")
        }
        return decide(effect)
    }

    public func ask<Effect: ScopedEffect>(about effect: Effect) async -> EffectAnswer {
        guard let ask = answers[ObjectIdentifier(Effect.self)] else {
            return .denied("the '\(effect.name)' effect is not granted by this authority")
        }
        return await ask(effect)
    }
}

/// Thrown when an ``Authority`` refuses to open a scope.
public struct EffectDenied: Error, Equatable, Sendable, CustomStringConvertible {
    /// The denied effect's ``ScopedEffect/name``.
    public let effect: String
    /// Why the authority refused.
    public let reason: String

    public init(effect: String, reason: String) {
        self.effect = effect
        self.reason = reason
    }

    public var description: String { "effect '\(effect)' denied: \(reason)" }
}

/// Reports every effect decision at the scope gate — the audit hook the
/// "watch the denial log, widen lanes by evidence" discipline needs. Silent
/// by default; the application installs its observer once at bootstrap.
/// Grants and denials both flow through, so the log measures how lanes are
/// actually used, not just how they fail.
public enum EffectAudit {
    // The closure rides in a box on purpose. A *bare* function value stored
    // in `Mutex`'s generic storage is re-wrapped in a re-abstraction thunk on
    // every round-trip through `withLock`'s `inout` boundary, and each wrap
    // *nests* instead of replacing (swiftlang/swift#54724, #49727). `record`
    // is called from many generic specializations at once (`withEffect`,
    // many generic effect operations) whose representations alternate, so
    // the stored closure never converges and gains one thunk layer per call —
    // calling it walks the whole nest, and the process dies of stack overflow
    // after hours of healthy uptime (crash point scales linearly with stack
    // size). Boxing the closure in a struct avoids the conversion entirely:
    // the struct's type matches exactly on both sides of the boundary, so
    // nothing is re-abstracted and nothing accumulates.
    private struct ObserverBox: Sendable {
        var observe: @Sendable (any ScopedEffect, EffectDecision) -> Void
    }

    // `nil` means "no observer": `record` is then a load, a nil check, and a
    // return.
    private static let observer = Mutex<ObserverBox?>(nil)

    /// Installs the process-wide observer (once, at bootstrap). `nil`
    /// restores silence.
    public static func install(_ observer: (@Sendable (any ScopedEffect, EffectDecision) -> Void)?) {
        self.observer.withLock { $0 = observer.map { ObserverBox(observe: $0) } }
    }

    static func record(_ effect: any ScopedEffect, _ decision: EffectDecision) {
        // Snapshot, then call outside the lock: the observer runs arbitrary
        // code (logging, IO) and no lock should be held across it.
        guard let box = observer.withLock({ $0 }) else { return }
        box.observe(effect, decision)
    }
}

/// Opens an effect scope only if `authority` grants the activation, throwing
/// ``EffectDenied`` otherwise.
///
/// This is the runtime choke point: the effect configuration and the
/// authority are both values, so the decision is pure and evaluated once per
/// activation, *before* any token exists. One that needs asking waits for the
/// authority's answer. On `.granted` the module's internal token-minting scope
/// opens and vends its token.
public func withEffect<Effect: ScopedEffect, Result>(
    _ effect: Effect,
    authority: any Authority,
    isolation: isolated (any Actor)? = #isolation,
    operation: (borrowing EffectToken<Effect>) async throws -> Result
) async throws -> Result {
    switch await answer(of: authority, on: effect) {
    case .granted:
        return try await _withEffectUnchecked(
            effect,
            authority: authority,
            operation: operation
        )
    case .denied(let reason):
        throw EffectDenied(effect: effect.name, reason: reason)
    }
}

/// What `authority` comes to for one activation of `effect`: its decision, or, when that needs
/// asking, its answer. Each is recorded.
func answer<Effect: ScopedEffect>(of authority: any Authority, on effect: Effect) async -> EffectAnswer {
    let decision = authority.decision(on: effect)
    EffectAudit.record(effect, decision)
    switch decision {
    case .granted: return .granted
    case .denied(let reason): return .denied(reason)
    case .needs:
        let answer = await authority.ask(about: effect)
        EffectAudit.record(effect, answer.decision)
        return answer
    }
}
