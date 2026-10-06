import AnyLanguageModel
import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A heuristic token estimator for hosts that explicitly choose an estimate.
/// It is not a substitute for a provider's preflight tokenizer: the JSON
/// representation used here is not necessarily the provider's rendered chat
/// template. Runtime code should use a provider measurement when available and
/// wait for an explicit overflow when it is not.
///
/// Exact counts need each model's tokenizer; a compactor only needs to know
/// "are we near the window", so the estimator counts characters and applies a
/// fixed per-message overhead (role, separators, framing). Tune
/// `charactersPerToken` downward for tokenizer-heavy content (CJK, code).
public struct TokenEstimator: Sendable {
    /// Roughly 4 characters per token for English-ish text.
    public var charactersPerToken: Double
    /// Framing cost charged to every message.
    public var perMessageOverhead: Int

    /// Optional model-specific counter. Hosts can wrap a tokenizer already
    /// owned by their Qwen/MLX/llama.cpp endpoint. Absence uses this estimator
    /// only when the host explicitly asks for it; a configured counter failure
    /// propagates.
    public var exactCount: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)?

    public init(
        charactersPerToken: Double = 4.0,
        perMessageOverhead: Int = 4,
        exactCount: (@Sendable ([Transcript.Entry], [ToolDefinition]) async throws(AgentRuntimeError) -> Int)? = nil
    ) {
        self.charactersPerToken = charactersPerToken
        self.perMessageOverhead = perMessageOverhead
        self.exactCount = exactCount
    }

    /// Uses a Hugging Face tokenizer and chat template for the exact request
    /// shape used by a local model (for example Qwen served by Ollama).
    /// Provider-reported usage still wins for accounting; this counter is the
    /// preflight path used to decide whether compaction is needed.
    public init(
        tokenizer: TokenCounter,
        charactersPerToken: Double = 4.0,
        perMessageOverhead: Int = 4
    ) {
        self.init(
            charactersPerToken: charactersPerToken,
            perMessageOverhead: perMessageOverhead,
            exactCount: {
                (messages: [Transcript.Entry], tools: [ToolDefinition]) async throws(AgentRuntimeError) -> Int in
                do {
                    return try tokenizer.count(messages: messages, tools: tools)
                } catch is CancellationError {
                    throw .cancelled
                } catch {
                    throw .infrastructureFailure("Token counting failed: \(error)")
                }
            }
        )
    }

    public func estimate(_ message: ChatMessage) -> Int {
        perMessageOverhead + estimate(characters(of: message))
    }

    public func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    /// Estimates the actual request payload presented to the model. Tool
    /// schemas are included because providers place them in the prompt even
    /// though they are not ordinary chat messages.
    public func estimate(
        messages: [Transcript.Entry],
        tools: [ToolDefinition]
    ) async throws(AgentRuntimeError) -> Int {
        if let exactCount {
            return max(try await exactCount(messages, tools), 0)
        }

        var messageTokens = 0
        for message in messages {
            messageTokens += perMessageOverhead + estimate(try encodedCharacterCount(message))
        }
        var toolTokens = 0
        for tool in tools {
            toolTokens += estimate(try encodedCharacterCount(tool))
        }
        return messageTokens + toolTokens
    }

    /// The token estimate of a raw text fragment (system prompt, memory
    /// entry, summary).
    public func estimate(_ text: String) -> Int {
        estimate(text.count)
    }

    private func estimate(_ characters: Int) -> Int {
        Int((Double(characters) / charactersPerToken).rounded(.up))
    }

    private func encodedCharacterCount<T: Encodable>(_ value: T) throws(AgentRuntimeError) -> Int {
        do {
            return try JSONEncoder().encode(value).count
        } catch {
            throw .infrastructureFailure("Could not encode the model request for token estimation.")
        }
    }

    private func characters(of message: ChatMessage) -> Int {
        switch message {
        case .text(_, let content, _):
            return content.count
        case .response(_, let payload, _):
            return payload.jsonString.count
        case .toolCall(let calls, _):
            return calls.reduce(0) { $0 + $1.name.count + $1.arguments.jsonString.count }
        case .assistantToolCall(let round, _):
            let narration = round.narration.map { characters(of: $0.segments) } ?? 0
            let reasoning = characters(of: round.reasoning)
            return narration
                + reasoning
                + round.calls.reduce(0) { $0 + $1.name.count + $1.arguments.jsonString.count }
        case .toolResult(_, let name, let output, _, _):
            return name.count + characters(of: output.transcriptSegments)
        case .failure(let error, _):
            return String(describing: error).count
        case .decisionRequest(_, let question, let options, _):
            return options.reduce(question.count) { $0 + $1.label.count }
        case .decisionResolved(_, let question, let resolution, let comment, _):
            return question.count + resolution.count + (comment?.count ?? 0)
        }
    }

    private func characters(of segments: [Transcript.Segment]) -> Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .text(let value):
                return total + value.content.count
            case .structure(let value):
                return total + value.content.jsonString.count
            case .image:
                return total + 1
            }
        }
    }
}
