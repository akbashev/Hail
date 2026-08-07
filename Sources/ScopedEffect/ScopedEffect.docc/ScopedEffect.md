# ``ScopedEffect``

Scoped side effects for tool-calling agents: `~Escapable` capability tokens checked against a runtime authority.

## Overview

ScopedEffect adapts Odersky et al., *Securing Agents with Tracked Capabilities* (CAIS 2026) to Swift: an effect scope vends a non-escapable, non-`Sendable` ``EffectToken`` that must be presented to perform the effect, so bypassing the funnel is unrepresentable. Every token is checked against an ``Authority``, which is deny-by-default; concrete effect domains and their policies live beside the implementations that perform them.

The module also carries the secrets vocabulary: values ride as ``Classified`` (non-`Codable`, redacted) and are referenced from configs as ``SecretRef``, so secrets never touch journals or UI.

ScopedEffect is a self-contained leaf module with no dependency on Hail's agent or model runtimes.

## Topics

### The mechanism

- ``ScopedEffect``
- ``EffectToken``

### Authority

- ``Authority``
- ``EffectDecision``
- ``CompositeAuthority``
- ``FullAuthority``
- ``EffectDenied``
- ``EffectAudit``

### Secrets

- ``Classified``
- ``SecretAccess``
- ``SecretRef``
