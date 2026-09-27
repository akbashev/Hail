import AnyLanguageModel
import CryptoKit
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A harness-owned conversation session id (kimi ACP, Claude CLI, or Codex
/// App Server thread), journaled so a restart can resume it.
public struct SessionID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The fingerprint of the agent identity (role prompt + model) a harness
/// session was created with. A mismatch invalidates the session and forces a
/// full bootstrap — see ``AgentSessionIdentity``.
public struct SessionIdentity: RawRepresentable, Codable, Sendable, Hashable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The per-turn delta handed to session-owning endpoints (kimi ACP, Claude CLI).
///
/// Session-owning harnesses keep the conversation in their own session, so a
/// warm session only needs what is genuinely new this turn; the full message
/// list is sent whenever a provider session is created or its identity changes.
/// The journal stays the durable source of truth; the provider session is only
/// an optional continuation handle.
///
/// INVARIANT: warm deltas are order-sensitive and not self-healing, so this
/// contract depends on strictly one in-flight turn per (agent, context)
/// session. `Agent` guarantees that today by chaining turns through its
/// serialized processing task — if turns are ever parallelized, warm deltas
/// would corrupt session context and this design must be revisited.
public struct TurnDelta: Sendable {
    /// The messages that are new to this turn. The transcript history is
    /// supplied separately as ``SessionOwningEndpoint/stream(request:delta:authority:tools:generating:purpose:)``'s
    /// request and can never be stored in this value by accident.
    public struct Current: Sendable {
        public let entries: [Transcript.Entry]

        public init(entries: [Transcript.Entry]) {
            self.entries = entries
        }
    }

    public let current: Current

    /// Fingerprint of the agent's stable identity (role prompt + model). A
    /// mismatch against the live session's fingerprint invalidates the session
    /// and forces a full bootstrap.
    public let sessionIdentity: SessionIdentity

    public init(
        currentEntries: [Transcript.Entry],
        sessionIdentity: SessionIdentity
    ) {
        self.current = Current(entries: currentEntries)
        self.sessionIdentity = sessionIdentity
    }
}

/// A journaled harness session to resume after a restart: the CLI session id
/// plus the identity fingerprint it was created with. The identity lets the
/// endpoint refuse a stale resume (config changed since) and bootstrap
/// instead.
public struct ModelSessionResume: Codable, Sendable, Equatable {
    public let id: SessionID
    public let identity: SessionIdentity

    public init(id: SessionID, identity: SessionIdentity) {
        self.id = id
        self.identity = identity
    }
}

/// A model endpoint backed by a harness that owns a stateful conversation
/// session (the local `kimi`/`claude` CLIs or Codex App Server).
///
/// On every turn the reasoning loop hands the endpoint the typed turn input,
/// the full transcript entries for cold bootstraps, and the per-turn
/// ``TurnDelta``. The
/// endpoint — which alone knows whether its session is alive — sends only the
/// delta on a warm session and bootstraps with the full context on a cold one.
/// Stateless endpoints (plain chat-model APIs) use the same transcript-based
/// ``ModelEndpoint`` operation.
public protocol SessionOwningEndpoint: ModelEndpoint {
    /// The harness session id currently in use, if any. The reasoning loop
    /// journals it after a turn so a restart can resume the session.
    var currentSessionID: SessionID? { get async }

    /// Streams one turn. `authority` is the turn's effect lane: the harness's
    /// own effects (fs/terminal delegation, the process spawn) are checked
    /// against it for this prompt. Because turns are serialized per agent, the
    /// endpoint applies it at prompt start and needs no restore — the next
    /// turn simply carries its own.
    func stream<Input, Output>(
        request: ModelRequest<Input>,
        delta: TurnDelta,
        authority: any Authority,
        tools: [AnyTool],
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable,
        Output.PartiallyGenerated: Sendable

    /// Tears down the live harness session, killing the harness process if
    /// one is running. Called when the owning agent deactivates; the next turn
    /// cold-bootstraps (resuming from the journaled session id when one
    /// exists). Harnesses whose process does not outlive a turn need do
    /// nothing — the default is a no-op.
    func terminateSession() async
}

extension SessionOwningEndpoint {
    public var contextOwnership: ModelContextOwnership { .endpointSession }
    public func terminateSession() async {}
}

/// Fingerprints an agent's stable session identity. The fingerprint changes
/// exactly when a warm session would run on stale configuration: a role-prompt
/// edit or a model switch. It deliberately excludes per-turn instructions,
/// memory, and the conversation thread — those ride the delta.
public enum AgentSessionIdentity {
    public static func fingerprint(
        model: String,
        reasoningEffort: ReasoningEffort? = nil,
        systemPrompt: String,
        personaInstructions: String? = nil,
        configurationIdentity: String? = nil
    ) -> SessionIdentity {
        let value = [
            model,
            reasoningEffort?.rawValue ?? "provider-default",
            systemPrompt,
            personaInstructions ?? "",
            configurationIdentity ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(value.utf8))
        return SessionIdentity(rawValue: digest.map { String(format: "%02x", $0) }.joined())
    }
}
