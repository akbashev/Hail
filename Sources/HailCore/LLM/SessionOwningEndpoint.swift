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
/// list is sent once, as the cold bootstrap. The journal stays the durable
/// source of truth — the harness session is an ephemeral cache in front of it.
///
/// INVARIANT: warm deltas are order-sensitive and not self-healing, so this
/// contract depends on strictly one in-flight turn per (agent, context)
/// session. `Agent` guarantees that today by chaining turns through its
/// serialized processing task — if turns are ever parallelized, warm deltas
/// would corrupt session context and this design must be revisited.
public struct TurnDelta: Sendable {
    /// New content for this turn only: per-turn instructions followed by the
    /// new input message. Never contains thread history.
    public var messages: [LLMMessage]

    /// The agent's current working memory. The session re-sends it only when
    /// it changed since the last send, framed as superseding earlier memory.
    public var workingMemory: [String]

    /// Fingerprint of the agent's stable identity (role prompt + model). A
    /// mismatch against the live session's fingerprint invalidates the session
    /// and forces a full bootstrap.
    public var sessionIdentity: SessionIdentity

    public init(messages: [LLMMessage], workingMemory: [String], sessionIdentity: SessionIdentity) {
        self.messages = messages
        self.workingMemory = workingMemory
        self.sessionIdentity = sessionIdentity
    }
}

/// A journaled harness session to resume after a restart: the CLI session id
/// plus the identity fingerprint it was created with. The identity lets the
/// endpoint refuse a stale resume (config changed since) and bootstrap
/// instead.
public struct ModelSessionResume: Sendable, Equatable {
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
/// On every turn the reasoning loop hands the endpoint both the full context
/// (`messages`, for cold bootstraps) and the per-turn ``TurnDelta``. The
/// endpoint — which alone knows whether its session is alive — sends only the
/// delta on a warm session and bootstraps with the full context on a cold one.
/// Stateless endpoints (plain chat-model APIs) do not conform; the loop calls
/// their plain `stream(messages:tools:)` instead.
public protocol SessionOwningEndpoint: ModelEndpoint {
    /// The harness session id currently in use, if any. The reasoning loop
    /// journals it after a turn so a restart can resume the session.
    var currentSessionID: SessionID? { get async }

    /// Streams one turn. `authority` is the turn's effect lane: the harness's
    /// own effects (fs/terminal delegation, the process spawn) are checked
    /// against it for this prompt. Because turns are serialized per agent, the
    /// endpoint applies it at prompt start and needs no restore — the next
    /// turn simply carries its own.
    func stream<T: AgentOutput>(
        messages: [LLMMessage],
        delta: TurnDelta,
        authority: any Authority,
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>>

    /// Tears down the live harness session, killing the harness process if
    /// one is running. Called when the owning agent deactivates; the next turn
    /// cold-bootstraps (resuming from the journaled session id when one
    /// exists). Harnesses whose process does not outlive a turn need do
    /// nothing — the default is a no-op.
    func terminateSession() async
}

extension SessionOwningEndpoint {
    public func terminateSession() async {}
}

/// Fingerprints an agent's stable session identity. The fingerprint changes
/// exactly when a warm session would run on stale configuration: a role-prompt
/// edit or a model switch. It deliberately excludes per-turn instructions,
/// memory, and the conversation thread — those ride the delta.
public enum AgentSessionIdentity {
    public static func fingerprint(model: String, systemPrompt: String) -> SessionIdentity {
        let digest = SHA256.hash(data: Data((model + "\u{1F}" + systemPrompt).utf8))
        return SessionIdentity(rawValue: digest.map { String(format: "%02x", $0) }.joined())
    }
}
