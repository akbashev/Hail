import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A value that can enter an agent turn as a typed input.
///
/// The runtime does not interpret the input semantically; it only asks the
/// value to produce a ``ChatMessage`` that can be journaled and rendered by
/// the model adapter. This keeps product-specific payloads out of
/// ``Hail`` while still giving the agent a typed input surface.
public protocol AgentInput: Codable & Sendable {
    /// Optional stable identity supplied by the host for the input that
    /// starts this turn. Hail carries it only through turn-tool resolution;
    /// it does not interpret or persist the value.
    var inputID: String? { get }

    /// Returns the chat message representation of this input.
    ///
    /// The message is stored in the agent's event journal and appended to the
    /// LLM context for the turn.
    func asChatMessage(timestamp: Date) -> ChatMessage

    /// Optional context that belongs only to this input.
    ///
    /// This is request-local data — timestamps, retrieved facts, profile
    /// details — never behavioral instructions, which keep their
    /// system/developer role. The runtime places this context after the
    /// durable history and immediately before the current input. It is
    /// intentionally not a system message:
    /// providers such as Ollama collate every system message at the front of
    /// the request, which would make changing per-turn data invalidate the
    /// reusable prompt prefix.
    func turnContext() -> [String]
}

extension AgentInput {
    public var inputID: String? { nil }

    public func turnContext() -> [String] { [] }
}

extension String: AgentInput {
    public func asChatMessage(timestamp: Date) -> ChatMessage {
        .text(sender: "user", content: self, timestamp: timestamp)
    }
}

extension ChatMessage: AgentInput {
    /// A chat message is its own chat representation; the timestamp is already
    /// embedded in the value. Returning `self` verbatim lets an interrupted
    /// turn be re-run with the exact message that was journaled before the
    /// crash, so the re-emitted `messageReceived` event folds idempotently.
    public func asChatMessage(timestamp: Date) -> ChatMessage {
        self
    }
}
