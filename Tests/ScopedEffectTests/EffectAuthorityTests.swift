import ScopedEffect
import Synchronization
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A demo effect for the decision layer: configuration on the outside,
/// operations gated on the token.
private struct DecisionGreeterEffect: ScopedEffect {
    let name = "greeter"
    let greeting: String
}

/// A second domain, to prove per-domain decisions stay separate.
private struct FarewellEffect: ScopedEffect {
    let name = "farewell"
}

extension EffectToken where Effect == DecisionGreeterEffect {
    func greet(_ who: String) -> String {
        withConfiguration { "\($0.greeting), \(who)!" }
    }
}

@Suite("Effect authority decisions")
struct EffectAuthorityTests {

    @Test("An empty authority denies by default")
    func denyByDefault() {
        let authority = CompositeAuthority()
        #expect(
            authority.decision(on: DecisionGreeterEffect(greeting: "Hi"))
                != .granted
        )
    }

    @Test("granting(for:decide:) applies the closure to its domain only")
    func compositeLookup() {
        let authority = CompositeAuthority()
            .granting(for: DecisionGreeterEffect.self) { effect in
                effect.greeting.isEmpty ? .denied("empty greeting") : .granted
            }

        #expect(authority.decision(on: DecisionGreeterEffect(greeting: "Hello")) == .granted)
        #expect(
            authority.decision(on: DecisionGreeterEffect(greeting: "")) == .denied("empty greeting")
        )
        // A domain with no closure stays closed.
        #expect(authority.decision(on: FarewellEffect()) != .granted)
    }

    @Test("grantingAll(for:) grants its domain unconditionally")
    func grantingAll() {
        let authority = CompositeAuthority()
            .grantingAll(for: DecisionGreeterEffect.self)
        #expect(authority.decision(on: DecisionGreeterEffect(greeting: "")) == .granted)
        #expect(authority.decision(on: FarewellEffect()) != .granted)
    }

    @Test("Builders return copies and do not mutate the receiver")
    func valueSemantics() {
        let base = CompositeAuthority()
        let extended = base.grantingAll(for: DecisionGreeterEffect.self)
        #expect(base.decision(on: DecisionGreeterEffect(greeting: "Hi")) != .granted)
        #expect(extended.decision(on: DecisionGreeterEffect(greeting: "Hi")) == .granted)
    }

    @Test("FullAuthority grants any domain")
    func fullAuthority() {
        let authority = FullAuthority()
        #expect(authority.decision(on: DecisionGreeterEffect(greeting: "")) == .granted)
        #expect(authority.decision(on: FarewellEffect()) == .granted)
    }

    @Test("The gated scope runs on grant and vends a working token")
    func gatedScopeRunsOnGrant() async throws {
        let authority = CompositeAuthority().grantingAll(for: DecisionGreeterEffect.self)
        let greeting = try await withEffect(DecisionGreeterEffect(greeting: "Hello"), authority: authority) { token in
            token.greet("authority")
        }
        #expect(greeting == "Hello, authority!")
    }

    @Test("The gated scope throws EffectDenied before any token exists")
    func gatedScopeThrowsOnDeny() async {
        let authority = CompositeAuthority()
            .granting(for: DecisionGreeterEffect.self) { _ in .denied("test refusal") }
        var activated = false
        do {
            _ = try await withEffect(DecisionGreeterEffect(greeting: "Hello"), authority: authority) { token in
                activated = true
                return token.greet("x")
            }
            Issue.record("expected EffectDenied")
        } catch let denial as EffectDenied {
            #expect(denial.effect == "greeter")
            #expect(denial.reason == "test refusal")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(!activated)
    }

    @Test("Deny-by-default also closes the gated scope")
    func gatedScopeDenyByDefault() async {
        await #expect(throws: EffectDenied.self) {
            try await withEffect(DecisionGreeterEffect(greeting: "Hi"), authority: CompositeAuthority()) { token in
                token.greet("x")
            }
        }
    }

    // The observer is process-global and EffectAuditStressTests swaps it too;
    // exclusivity comes from the turnstile (see EffectAuditStressTests.swift),
    // not from .serialized, which cannot order tests across suites.
    @Test("Every gated decision is reported to the audit observer")
    func auditReportsDecisions() async throws {
        await EffectAuditTurnstile.shared.enter()
        defer { Task { await EffectAuditTurnstile.shared.leave() } }
        let entries = Mutex<[(String, EffectDecision)]>([])
        EffectAudit.install { effect, decision in
            entries.withLock { $0.append((effect.name, decision)) }
        }
        // Restore silence however the test ends, so a failure below can't
        // leave the process-global observer installed for other suites.
        defer { EffectAudit.install(nil) }

        let effect = AuditProbeEffect()
        let granting = CompositeAuthority().grantingAll(for: AuditProbeEffect.self)
        _ = try await withEffect(effect, authority: granting) { token in
            token.probe()
        }
        await #expect(throws: EffectDenied.self) {
            try await withEffect(effect, authority: CompositeAuthority()) { token in
                token.probe()
            }
        }

        // Suites run in parallel, so other tests' decisions land here too —
        // filter to this probe's effect.
        let recorded = entries.withLock { $0 }.filter { $0.0 == "audit-probe" }
        // #require, not #expect: a failed #expect would continue into the
        // indexing below and trap, crashing the whole test process.
        try #require(recorded.count == 2)
        #expect(recorded[0].1 == .granted)
        #expect(recorded[1].1 != .granted)
    }
}

/// The audit test's own effect, so parallel suites don't pollute its entries.
private struct AuditProbeEffect: ScopedEffect {
    let name = "audit-probe"
}

extension EffectToken where Effect == AuditProbeEffect {
    func probe() -> String { "probed" }
}
