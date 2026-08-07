/// Opens a scope in which `effect`'s live capability may be used, runs
/// `operation` with it, and revokes it by construction when the scope ends.
///
/// - `async`: the operation may suspend — the effect may perform IO.
/// - `rethrows`: the scope itself never fails; a non-throwing operation
///   needs no `try`. Purity of the body stays visible at the call site.
/// - `isolated`: the operation runs on the caller's isolation domain, and
///   the non-`Sendable` token is pinned to it — the capability cannot hop
///   actors.
///
/// This is the internal token-minting mechanism: lexical scope in,
/// non-escapable token out. It is deliberately not public; clients must use
/// the authority-gated `withEffect(_:authority:)` entry point.
func _withEffectUnchecked<Effect: ScopedEffect, Result>(
    _ effect: Effect,
    isolation: isolated (any Actor)? = #isolation,
    operation: (borrowing EffectToken<Effect>) async throws -> Result
) async rethrows -> Result {
    try await operation(EffectToken(effect))
}
