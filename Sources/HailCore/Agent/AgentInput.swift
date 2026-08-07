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
    /// Returns the chat message representation of this input.
    ///
    /// The message is stored in the agent's event journal and appended to the
    /// LLM context for the turn.
    func asChatMessage(timestamp: Date) -> ChatMessage

    /// Optional system instructions that belong to this specific input.
    ///
    /// The runtime appends these as system messages after the generic context
    /// so the model sees input-specific rules (e.g. which outcome tool to call)
    /// without the prompt policy needing to know about product types.
    func systemInstructions() -> [String]
}

extension AgentInput {
    public func systemInstructions() -> [String] { [] }
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
