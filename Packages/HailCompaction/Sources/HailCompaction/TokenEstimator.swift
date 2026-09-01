import HailCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A heuristic token estimator used to decide when compaction is due.
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
    /// owned by their Qwen/MLX/llama.cpp endpoint. If it fails, estimation
    /// falls back to the conservative character-based calculation.
    public var exactCount: (@Sendable ([LLMMessage], [LLMToolSchema]) async throws -> Int)?

    public init(
        charactersPerToken: Double = 4.0,
        perMessageOverhead: Int = 4,
        exactCount: (@Sendable ([LLMMessage], [LLMToolSchema]) async throws -> Int)? = nil
    ) {
        self.charactersPerToken = charactersPerToken
        self.perMessageOverhead = perMessageOverhead
        self.exactCount = exactCount
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
        messages: [LLMMessage],
        tools: [LLMToolSchema]
    ) async -> Int {
        if let exactCount, let count = try? await exactCount(messages, tools) {
            return max(count, 0)
        }

        let messageTokens = messages.reduce(0) { total, message in
            total + perMessageOverhead + estimate(encodedCharacterCount(message))
        }
        let toolTokens = tools.reduce(0) { total, tool in
            total + estimate(encodedCharacterCount(tool))
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

    private func encodedCharacterCount<T: Encodable>(_ value: T) -> Int {
        guard let data = try? JSONEncoder().encode(value) else {
            return String(describing: value).count
        }
        return data.count
    }

    private func characters(of message: ChatMessage) -> Int {
        switch message {
        case .text(_, let content, _):
            return content.count
        case .response(_, let payload, _):
            return payload.count
        case .toolCall(let calls, _):
            return calls.reduce(0) { $0 + $1.name.count + $1.arguments.json.count }
        case .toolResult(_, let content, _):
            return content.count
        case .failure(let error, _):
            return String(describing: error).count
        case .decisionRequest(_, let question, let options, _):
            return options.reduce(question.count) { $0 + $1.label.count }
        case .decisionResolved(_, let question, let resolution, let comment, _):
            return question.count + resolution.count + (comment?.count ?? 0)
        }
    }
}
