import ScopedEffect
import Testing

/// Regression cover for the thunk-accumulation stack overflow
/// (swiftlang/swift#54724, #49727): a closure stored in `Mutex` and read
/// back per call gains a nested re-abstraction thunk layer per round-trip
/// when called from alternating generic specializations, until the stack
/// blows. `EffectAudit` boxes its observer closure in a struct precisely to
/// avoid the conversion; this loop would overflow (~50k iterations on an
/// 8 MB stack) if the box were ever removed. Two distinct generic entry
/// points are required — a single one converges and never accumulates.
@Suite("EffectAudit stress")
struct EffectAuditStressTests {
    @Test("100k alternating gated decisions leave no thunk growth")
    func alternatingDecisions() async throws {
        // A non-nil observer must be stored — the stored closure is the value
        // that accumulated thunk layers. (No counting assertion: the observer
        // is process-global and parallel suites replace it, so exact counts
        // race. Survival of the loop is the assertion — unboxed, this
        // overflowed the stack at ~50k iterations.)
        EffectAudit.install { _, _ in }
        defer { EffectAudit.install(nil) }

        let effect = StressProbeEffect()
        let authority = CompositeAuthority().grantingAll(for: StressProbeEffect.self)
        for i in 0..<100_000 {
            _ = try await gatedPathA(effect, authority: authority, i)
            _ = try await gatedPathB(effect, authority: authority, i)
        }
    }

    // Two differently-generic shells so `withEffect` (and its audit call) is
    // reached through two distinct specializations — the alternation is what
    // drove the accumulation.
    @inline(never)
    private func gatedPathA<Input>(_ effect: StressProbeEffect, authority: any Authority, _ input: Input) async throws
        -> String
    {
        try await withEffect(effect, authority: authority) { $0.stressProbe() }
    }

    @inline(never)
    private func gatedPathB<Input>(_ effect: StressProbeEffect, authority: any Authority, _ input: Input) async throws
        -> Int
    {
        try await withEffect(effect, authority: authority) { $0.stressProbe().count }
    }
}

private struct StressProbeEffect: ScopedEffect {
    let name = "stress-probe"
}

extension EffectToken where Effect == StressProbeEffect {
    func stressProbe() -> String { "probed" }
}
