# ScopedEffect

Lexical scopes that vend non-escapable effect capabilities, in the style of
Swift's `withSomething` pattern — `async`, throwing, isolated: every
external effect goes through a scope, and the live capability (the token)
cannot escape it.

The design goal comes from *Securing Agents with Tracked Capabilities*
(Odersky et al., CAIS 2026, [arXiv:2603.00991](https://arxiv.org/abs/2603.00991);
companion article: [Tracked Capabilities for Safer Agents](https://martinodersky.substack.com/p/tracked-capabilities-for-safer-agents)):
a capability should be held only for a defined part of a computation —
revocation by construction — and safety should be a property of the
infrastructure, enforced by the compiler where possible. Hail adapts the
idea to Swift and to tool-call agents: `~Escapable` tokens plus a runtime
authority at the scope gate stand in for capture checking, and the gated
effects are tool calls (file/terminal/process/network), not arbitrary
code execution.

## Shape

```swift
// 1. An effect is configuration, as a value. It is data, not authority.
struct ModelEffect: ScopedEffect {
    let name = "model"
    let model: String
}

// 2. Operations live on the token. No token, no effect.
extension EffectToken where Effect == ModelEffect {
    func complete(_ prompt: String) async throws -> String {
        ...
    }
}

// 3. The capability exists only inside the scope.
let reply = try await withEffect(ModelEffect(model: "k3"), authority: authority) { model in
    try await model.complete("hello")
}
```

- `withEffect` is `async throws` because authority may deny the requested
  effect, and takes an `isolated` parameter so the body runs on the caller's
  isolation.
- `EffectToken` is `~Escapable` + `~Sendable`: the compiler kills every
  attempt to smuggle the capability out of the scope. Its init is internal,
  so the scope function is the only place a token can come from.

## Module boundary

This target is the pure abstraction, in three layers:

- **Mechanism** (`ScopedEffect.swift`, `withEffect.swift`): the `ScopedEffect`
  protocol, the `~Escapable`/`~Sendable` `EffectToken`, and the internal
  token-minting scope function.
- **Decision vocabulary** (`Authority.swift`): `EffectDecision`, the
  `Authority` protocol (deny-by-default), `CompositeAuthority`,
  `FullAuthority`, `EffectDenied`, `EffectAudit` (every decision at the gate
  reported to one observer installed at bootstrap — grants and denials both),
  and the gated `withEffect(_:authority:)` composition — the choke point that
  asks an authority before any token exists.
- **Secrets** (`Classified.swift`, `SecretRef.swift`): `Classified`, a
  non-`Codable`, redacted wrapper whose `reveal(_:)` is gated on
  `SecretAccess`. The gate is a deliberate-act marker, not a security
  boundary — conformers are public-protocol open, so the known-conformer /
  known-`reveal(`-site discipline is enforced by a test tripwire
  (`SecretsGuardTests`); the real boundary is effect authority. `SecretRef`
  (`.env`/`.store`) is safe to persist while resolution remains a host concern.

Concrete effect domains are *not* here — implementation per package, not in
the abstraction. Each module defines its own effect in its own domain
language with its own authority, next to the code that performs it:
`FileEffect`/`TerminalEffect`/`ProcessEffect`/`NetworkEffect` +
the policy factories (`pathPolicy`, `readOnlyPathPolicy`,
`commandPolicy(allowing:)`, `hostPolicy(allowing:)`) in Hail
(`Sources/HailCore/Effects/`). Host-defined domains follow the same pattern. The
target stays self-contained and has no infrastructure dependencies.

## Spike findings (Swift 6.4 toolchain, tools 6.3)

Verified by tests (`swift test`) and by negative compile checks via a SwiftPM
client package:

| Guarantee | Result |
|---|---|
| Token usable inside the scope, **including across `await`** | ✅ holds |
| Raw scope mechanism is `rethrows` internally | ✅ holds; public activation is authority-gated and throwing |
| Body runs on the caller's actor isolation | ✅ holds |
| Authority grant/deny composition, typed denial | ✅ holds (this module's gated variant) |
| Token captured by `Task` / escaping closure | ✅ rejected — "lifetime-dependent variable escapes its scope" |
| Token sent to another actor | ✅ rejected — region isolation "sending risks data races" |
| Token returned as the operation's result | ✅ rejected — `~Escapable` ≠ escapable `Result` |

### Caveats

- **Requires the experimental `Lifetimes` feature** (`@_lifetime`) on both the
  library and every client target. The token's init is
  `@_lifetime(borrow effect)` over a `borrowing Effect` parameter storing
  `copy effect` — copy-dependence on escapable sources is rejected, borrow
  dependence is the conservative answer.
- **Configuration can be copied out** (`token.withConfiguration { $0 }`):
  implicit copies of a `borrowing` parameter are legal for `Copyable` types.
  Consequence: the effect value must hold *data only*; anything
  authority-bearing (live connections, closures capturing resources) must be
  acquired inside token operations, never stored in the configuration.
- **Protocol methods cannot return `~Escapable`** and `~Sendable` cannot be
  suppressed on associated types — which is why the token is a concrete
  generic type with operations as extensions, not an associated token type.
- **Enforcement is a SwiftPM/build-system property**: typechecking against
  the raw binary `.swiftmodule` with `swiftc` silently drops the
  lifetime/region checks. Consumers must come through SwiftPM.

## Open questions

- Granularity: settled. Per-domain scopes won, and the lane is an
  `Authority` value decided per agent (`CompositeAuthority` factories
  in Hail), not per scope call site.
- Whether a typed denial should carry the effect value (not just its name) —
  errors generic over `Effect` are awkward to catch; name strings won for now.
- Async `withConfiguration`: a borrowing parameter cannot be held across a
  suspension, so async operations must await *first*, then read configuration
  synchronously (or re-enter the token). Fine in practice so far.

## Status

A target of the Hail package (`Sources/ScopedEffect`, tests in
`Tests/ScopedEffectTests`); every Hail module that performs or gates
effects builds on it. Run its tests from the repo root:

```sh
swift test --filter ScopedEffectTests
```
