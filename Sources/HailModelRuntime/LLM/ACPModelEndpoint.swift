import ACPModel
import AnyLanguageModel
import HailCore
import Logging
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let logger = Logger(label: "ACPModelEndpoint")

/// A ``ModelEndpoint`` that drives a local CLI agent through the Agent Client
/// Protocol (ACP).
///
/// This is the provider-neutral core shared by every ACP-backed endpoint
/// (``KimiCodeEndpoint``, ``ClaudeCliEndpoint``, …). It consumes the native ACP
/// notification stream (`agent_message_chunk`, `agent_thought_chunk`,
/// `tool_call`, `tool_call_update`, `plan`, etc.) and maps it directly to
/// Hail ``ModelEvent`` values — it does not try to fit the ACP agent into
/// a generic chat-model abstraction.
///
/// Tool calls executed inside the agent process (via MCP) are surfaced as
/// `.status` events, not as Hail ``ModelEvent/toolCall`` events, because
/// Hail should not execute them again.
///
/// Concrete endpoints differ only in which command the underlying ``ACPSession``
/// launches; the `harness` label distinguishes them in logs.
///
/// Module-internal: it is an implementation detail shared by the public
/// ``KimiCodeEndpoint`` / ``ClaudeCliEndpoint`` wrappers, and it holds an
/// internal ``ACPSession``, so it is not part of the package's public surface.
struct ACPModelEndpoint: ModelEndpoint {
    let model: String
    let executionPolicy: AgentExecutionPolicy

    /// Short label identifying the backing agent in logs (e.g. `kimi-code`).
    private let harness: String
    private let session: ACPSession

    init(
        harness: String,
        model: String,
        executionPolicy: AgentExecutionPolicy,
        session: ACPSession
    ) {
        self.harness = harness
        self.model = model
        self.executionPolicy = executionPolicy
        self.session = session
    }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable
    {
        stream(
            entries: request.entries, turnDelta: nil, authority: authority, tools: tools.map(\.schema),
            generating: outputType, purpose: purpose)
    }

    /// The shared streaming body. With a precise ``TurnDelta`` from the
    /// reasoning loop the warm path sends only the new content; without one
    /// (plain ``ModelEndpoint`` calls) it falls back to the conversation tail.
    /// `authority` is the turn's effect lane; `nil` keeps the session's
    /// current authority.
    private func stream<Output>(
        entries: [Transcript.Entry],
        turnDelta: TurnDelta?,
        authority: (any Authority)? = nil,
        tools: [ToolDefinition],
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        _ = tools
        _ = purpose
        return AsyncStream(ModelEvent<Output>.self) { continuation in
            let task = Task {
                do {
                    let parts = turnParts(entries: entries, turnDelta: turnDelta, responseType: outputType)
                    let outcome = try await runPrompt(
                        bootstrap: parts.bootstrap,
                        delta: parts.delta,
                        identity: parts.identity,
                        authority: authority,
                        responseType: outputType,
                        continuation: continuation
                    )
                    if let outcome {
                        continuation.yield(.generated(outcome))
                    } else {
                        continuation.yield(
                            .failed(
                                ModelEndpointError.invalidResponse("Agent finished without producing a response.")
                            ))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Shared prompt runner

    /// Computes the bootstrap/delta/identity triple for one turn. With a
    /// precise ``TurnDelta`` from the reasoning loop the warm path sends only
    /// the new content; without one the delta falls back to the conversation
    /// tail and the identity to the system prefix.
    private func turnParts<T>(
        entries: [Transcript.Entry],
        turnDelta: TurnDelta?,
        responseType: T.Type
    ) -> (bootstrap: String, delta: String, identity: SessionIdentity)
    where T: Codable & Sendable & Generable {
        let bootstrap = Self.appendOutcomeInstruction(
            prompt: Self.formatPrompt(entries: entries),
            responseType: responseType
        )
        if let turnDelta {
            let delta = Self.appendOutcomeInstruction(
                prompt: Self.formatCompactEntries(turnDelta.current.entries),
                responseType: responseType
            )
            return (bootstrap, delta, turnDelta.sessionIdentity)
        }
        let delta = Self.appendOutcomeInstruction(
            prompt: Self.formatCompactEntries(
                entries.filter {
                    if case .instructions = $0 { return false }
                    return true
                }),
            responseType: responseType
        )
        let identity = AgentSessionIdentity.fingerprint(
            model: model,
            systemPrompt: entries.filter {
                if case .instructions = $0 { return true }
                return false
            }.map(Self.text).joined(separator: "\n\n")
        )
        return (bootstrap, delta, identity)
    }

    /// Runs a prompt through the ACP session, yielding activity through the
    /// continuation and decoding the declared output at this text-only
    /// adapter boundary. Tool notifications remain activity; they are not the
    /// model result.
    private func runPrompt<T>(
        bootstrap: String,
        delta: String,
        identity: SessionIdentity,
        authority: (any Authority)? = nil,
        responseType: T.Type,
        continuation: AsyncStream<ModelEvent<T>>.Continuation
    ) async throws -> T?
    where T: Codable & Sendable & Generable {
        let isStructured = T.self != String.self
        logger.info(
            "Starting \(harness) \(isStructured ? "structured" : "chat") stream",
            metadata: [
                "harness": .string(harness),
                "bootstrapLength": .string("\(bootstrap.count)"),
                "deltaLength": .string("\(delta.count)"),
                "responseType": .string("\(T.self)"),
            ]
        )
        continuation.yield(.activity(.status(GeneratedContent("Generating"))))

        let (stream, responseTask) = try await session.executeTurnPrompt(
            bootstrap: bootstrap,
            delta: delta,
            identity: identity,
            authority: authority
        )

        var collectedText = ""
        for try await event in stream {
            switch event {
            case .text(let fragment):
                logger.debug(
                    "\(harness) text fragment",
                    metadata: ["length": .string("\(fragment.count)")]
                )
                collectedText += fragment
                continuation.yield(.activity(.narrationDelta(GeneratedContent(fragment))))

            case .thought(let text):
                logger.debug("\(harness) thought fragment")
                continuation.yield(.activity(.reasoningDelta(GeneratedContent(text))))

            case .toolCall(let update):
                let name = update.title ?? update.kind.map { $0.rawValue } ?? "tool"
                logger.debug("\(harness) tool call", metadata: ["name": .string(name)])
                continuation.yield(.activity(.status(GeneratedContent("Calling \(name)."))))

            case .toolCallUpdate(let details):
                let name = details.title ?? details.kind.map { $0.rawValue } ?? "tool"
                let status = details.status.map { "\($0.rawValue)" } ?? "updated"
                logger.debug(
                    "\(harness) tool call update",
                    metadata: ["name": .string(name), "status": .string(status)]
                )
                continuation.yield(.activity(.status(GeneratedContent("\(name): \(status)."))))

            case .plan:
                logger.debug("\(harness) plan update")
                continuation.yield(.activity(.status(GeneratedContent("Plan updated."))))

            case .usage(let usageUpdate):
                logger.debug(
                    "\(harness) usage update",
                    metadata: [
                        "used": .string("\(usageUpdate.used)"),
                        "size": .string("\(usageUpdate.size)"),
                    ]
                )
                continuation.yield(
                    .contextUsage(
                        ContextUsage(
                            usedTokens: usageUpdate.used,
                            limitTokens: usageUpdate.size,
                            source: .reported
                        )))
            }
        }

        // A cancelled consumer ends the event stream above without waiting
        // for the prompt; the session's termination handler has already
        // cancelled the response task and sent `session/cancel` to the
        // harness. Awaiting an unstructured task's value does NOT unblock
        // when the waiter is cancelled, so check first instead of lingering
        // here until the turn ends naturally.
        try Task.checkCancellation()
        let response = try await responseTask.value
        if let usage = response.usage {
            continuation.yield(
                .usage(
                    ModelUsage(
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        reasoningTokens: usage.thoughtTokens,
                        cachedReadTokens: usage.cachedReadTokens,
                        cachedWriteTokens: usage.cachedWriteTokens,
                        totalTokens: usage.totalTokens,
                        source: .reported
                    )))
        }
        logger.info(
            "\(harness) turn completed",
            metadata: ["stopReason": .string("\(response.stopReason)")]
        )

        do {
            if let value = collectedText as? T {
                return value
            }
            return try T(GeneratedContent(json: collectedText))
        } catch {
            throw ModelEndpointError.invalidResponse(
                "ACP output did not satisfy \(T.self): \(error)"
            )
        }
    }

    // MARK: - Prompt formatting

    /// Formats the full message list into a single ACP prompt text. System
    /// messages appear first so the agent receives its role and contract before
    /// the user/tool transcript.
    private static func formatPrompt(entries: [Transcript.Entry]) -> String {
        let systemMessages = entries.filter {
            if case .instructions = $0 { return true }
            return false
        }
        let nonSystemMessages = entries.filter {
            if case .instructions = $0 { return false }
            return true
        }

        var parts: [String] = []
        if !systemMessages.isEmpty {
            parts.append(systemMessages.map(Self.text).joined(separator: "\n\n"))
        }
        if !nonSystemMessages.isEmpty {
            parts.append(formatCompactEntries(nonSystemMessages))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Formats a compact message transcript for the ACP agent.
    private static func formatCompactEntries(_ entries: [Transcript.Entry]) -> String {
        entries.map { entry in
            text(entry)
        }.joined(separator: "\n\n")
    }

    /// ACP is a text-only transport. Structured Hail content is serialized
    /// here, at this adapter boundary, rather than being flattened in Hail's
    /// transcript model.
    private static func text(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions(let value): return render(value.segments)
        case .prompt(let value): return "User: \(render(value.segments))"
        case .response(let value): return "Assistant: \(render(value.segments))"
        case .toolCalls(let value): return "Assistant tool calls: \(value.id)"
        case .toolOutput(let value): return "Tool result: \(render(value.segments))"
        }
    }

    private static func render(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let value): return value.content.jsonString
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }

    private static func appendOutcomeInstruction<T>(
        prompt: String,
        responseType: T.Type
    ) -> String where T: Codable & Sendable & Generable {
        prompt
    }
}

// MARK: - SessionOwningEndpoint

extension ACPModelEndpoint: SessionOwningEndpoint {
    var currentSessionID: SessionID? {
        get async {
            await session.currentSessionID
        }
    }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [AnyTool],
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable
    {
        stream(
            entries: request.entries, turnDelta: turnDelta, authority: authority, tools: tools.map(\.schema),
            generating: outputType, purpose: purpose)
    }

    func terminateSession() async {
        await session.terminate()
    }
}
