import HailCore
import AnyLanguageModel
import Tokenizers

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Counts the model-visible representation using a Hugging Face tokenizer and
/// its configured chat template. The endpoint should use the same template
/// when sending the request; otherwise this is a safe preflight estimate, not
/// an authoritative provider count.
public struct TokenCounter: Sendable {
    public let tokenizer: any Tokenizer

    private actor Cache {
        var values: [String: TokenCounter] = [:]

        func value(for key: String) -> TokenCounter? { values[key] }

        func insert(_ value: TokenCounter, for key: String) {
            values[key] = value
        }
    }

    private static let cache = Cache()

    public init(tokenizer: some Tokenizer) {
        self.tokenizer = tokenizer
    }

    /// Loads tokenizer assets from the Hugging Face Hub.
    public static func load(
        model: String,
        strict: Bool = true
    ) async throws -> TokenCounter {
        let tokenizer = try await AutoTokenizer.from(
            pretrained: model,
            strict: strict
        )
        return TokenCounter(tokenizer: tokenizer)
    }

    /// Loads tokenizer assets from a local model directory, without network
    /// access. The directory must contain the model's tokenizer files.
    public static func load(
        modelFolder: URL,
        strict: Bool = true
    ) async throws -> TokenCounter {
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder, strict: strict)
        return TokenCounter(tokenizer: tokenizer)
    }

    /// Loads and caches tokenizer assets by model identifier and strictness.
    /// This avoids reparsing the same tokenizer when multiple agents use one
    /// local model while keeping the ordinary `load` APIs uncached and
    /// deterministic for callers that want a fresh instance.
    public static func loadCached(
        model: String,
        strict: Bool = true
    ) async throws -> TokenCounter {
        let key = "hub:\(model)|strict:\(strict)"
        if let cached = await cache.value(for: key) { return cached }
        let loaded = try await load(model: model, strict: strict)
        await cache.insert(loaded, for: key)
        return loaded
    }

    /// Loads and caches tokenizer assets from a local model directory. The
    /// cache key is the standardized path, so the operation remains offline
    /// after the first load.
    public static func loadCached(
        modelFolder: URL,
        strict: Bool = true
    ) async throws -> TokenCounter {
        let key = "file:\(modelFolder.standardizedFileURL.path)|strict:\(strict)"
        if let cached = await cache.value(for: key) { return cached }
        let loaded = try await load(modelFolder: modelFolder, strict: strict)
        await cache.insert(loaded, for: key)
        return loaded
    }

    public func count(
        messages: [LLMMessage],
        tools: [ToolDefinition] = []
    ) throws -> Int {
        let prompt = messages.map(message)
        let toolSpecs = tools.isEmpty ? nil : tools.map(tool)
        return try tokenizer.applyChatTemplate(messages: prompt, tools: toolSpecs).count
    }

    private func message(_ message: LLMMessage) -> [String: any Sendable] {
        var result: [String: any Sendable] = [
            "role": message.role.rawValue,
            "content": message.content,
        ]
        if let name = message.name {
            result["name"] = name
        }
        if let toolCallID = message.toolCallID {
            result["tool_call_id"] = toolCallID
        }
        if let calls = message.toolCalls, !calls.isEmpty {
            result["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": call.type,
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ] as [String: any Sendable],
                ] as [String: any Sendable]
            }
        }
        return result
    }

    private func tool(_ tool: ToolDefinition) -> [String: any Sendable] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters(tool.parameters),
            ] as [String: any Sendable],
        ]
    }

    private func parameters(_ schema: GenerationSchema) -> [String: any Sendable] {
        guard
            let data = try? JSONEncoder().encode(schema),
            let value = try? JSONSerialization.jsonObject(with: data),
            let result = value as? [String: any Sendable]
        else {
            return [:]
        }
        return result
    }
}
