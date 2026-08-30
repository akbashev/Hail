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

    func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>> {
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    let parts = turnParts(messages: messages, turnDelta: nil, responseType: String.self)
                    let outcome = try await runPrompt(
                        bootstrap: parts.bootstrap,
                        delta: parts.delta,
                        memorySnapshot: parts.memorySnapshot,
                        identity: parts.identity,
                        responseType: String.self,
                        continuation: continuation
                    )
                    continuation.yield(.generated(outcome ?? ""))
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

    func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        stream(messages: messages, turnDelta: nil, tools: tools, responseType: responseType)
    }

    /// The shared streaming body. With a precise ``TurnDelta`` from the
    /// reasoning loop the warm path sends only the new content; without one
    /// (plain ``ModelEndpoint`` calls) it falls back to the conversation tail.
    /// `authority` is the turn's effect lane; `nil` keeps the session's
    /// current authority.
    private func stream<T: AgentOutput>(
        messages: [LLMMessage],
        turnDelta: TurnDelta?,
        authority: (any Authority)? = nil,
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    let parts = turnParts(messages: messages, turnDelta: turnDelta, responseType: T.self)
                    let outcome = try await runPrompt(
                        bootstrap: parts.bootstrap,
                        delta: parts.delta,
                        memorySnapshot: parts.memorySnapshot,
                        identity: parts.identity,
                        authority: authority,
                        responseType: T.self,
                        continuation: continuation
                    )
                    if let outcome {
                        continuation.yield(.generated(outcome))
                    } else {
                        let expectedTools = Self.expectedReportToolNames(for: T.self)
                        let reason =
                            expectedTools.isEmpty
                            ? "Agent finished without producing a response."
                            : "Agent finished without calling \(expectedTools.joined(separator: " or "))."
                        continuation.yield(
                            .failed(
                                ModelEndpointError.invalidResponse(reason)
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
    /// the new content (plus the memory snapshot when it changed); without one
    /// the delta falls back to the conversation tail and the identity to the
    /// system prefix.
    private func turnParts<T: AgentOutput>(
        messages: [LLMMessage],
        turnDelta: TurnDelta?,
        responseType: T.Type
    ) -> (bootstrap: String, delta: String, memorySnapshot: String?, identity: SessionIdentity) {
        let bootstrap = Self.appendOutcomeInstruction(
            prompt: Self.formatPrompt(messages: messages),
            responseType: responseType
        )
        if let turnDelta {
            let delta = Self.appendOutcomeInstruction(
                prompt: Self.formatCompactMessages(turnDelta.messages),
                responseType: responseType
            )
            let memorySnapshot =
                turnDelta.workingMemory.isEmpty
                ? nil
                : "Current working memory (supersedes any earlier memory in this session):\n"
                    + turnDelta.workingMemory.map { "- \($0)" }.joined(separator: "\n")
            return (bootstrap, delta, memorySnapshot, turnDelta.sessionIdentity)
        }
        let delta = Self.appendOutcomeInstruction(
            prompt: Self.formatCompactMessages(messages.filter { $0.role != .system }),
            responseType: responseType
        )
        let identity = AgentSessionIdentity.fingerprint(
            model: model,
            systemPrompt: messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        )
        return (bootstrap, delta, nil, identity)
    }

    /// Runs a prompt through the ACP session, yielding text/thinking/status
    /// events through the continuation and returning the decoded outcome (if any).
    ///
    /// For chat turns `T` is `String` and the returned value is the collected text.
    /// For structured turns `T` is an ``AgentOutput`` type decoded from a
    /// report-tool call. Plain-text JSON is not accepted here; that fallback
    /// belongs to non-tool providers through ``ModelEndpoint``.
    private func runPrompt<T: AgentOutput>(
        bootstrap: String,
        delta: String,
        memorySnapshot: String?,
        identity: SessionIdentity,
        authority: (any Authority)? = nil,
        responseType: T.Type,
        continuation: AsyncStream<ModelEvent<T>>.Continuation
    ) async throws -> T? {
        let isStructured: Bool =
            switch T.outputContract {
            case .plainText: false
            case .reportTool: true
            }
        let expectedReportTools = Self.expectedReportToolNames(for: T.self)
        logger.info(
            "Starting \(harness) \(isStructured ? "structured" : "chat") stream",
            metadata: [
                "harness": .string(harness),
                "bootstrapLength": .string("\(bootstrap.count)"),
                "deltaLength": .string("\(delta.count)"),
                "responseType": .string("\(T.self)"),
            ]
        )
        continuation.yield(.status("Generating..."))

        let (stream, responseTask) = try await session.executeTurnPrompt(
            bootstrap: bootstrap,
            delta: delta,
            memorySnapshot: memorySnapshot,
            identity: identity,
            authority: authority
        )

        var collectedText = ""
        var decodedOutcome: T?
        // ACP may send the report tool's arguments on the initial `toolCall`
        // notification or on a subsequent `toolCallUpdate`. Track the IDs of
        // report-outcome tool calls so updates can be decoded too.
        var reportToolCallIDs: Set<String> = []
        for try await event in stream {
            switch event {
            case .text(let fragment):
                logger.debug(
                    "\(harness) text fragment",
                    metadata: ["length": .string("\(fragment.count)")]
                )
                collectedText += fragment
                continuation.yield(.text(fragment))

            case .thought(let text):
                logger.debug("\(harness) thought fragment")
                continuation.yield(.thinking(text))

            case .toolCall(let update):
                let name = update.title ?? update.kind.map { $0.rawValue } ?? "tool"
                logger.debug("\(harness) tool call", metadata: ["name": .string(name)])
                if isStructured, Self.isReportOutcomeTool(name: name, expected: expectedReportTools) {
                    reportToolCallIDs.insert(update.toolCallId)
                    if let outcome = Self.decodeOutcome(from: update, as: T.self) {
                        decodedOutcome = outcome
                        continuation.yield(.status("Reporting outcome."))
                    } else {
                        continuation.yield(.status("Calling \(name)."))
                    }
                } else {
                    continuation.yield(.status("Calling \(name)."))
                }

            case .toolCallUpdate(let details):
                let name = details.title ?? details.kind.map { $0.rawValue } ?? "tool"
                let status = details.status.map { "\($0.rawValue)" } ?? "updated"
                logger.debug(
                    "\(harness) tool call update",
                    metadata: ["name": .string(name), "status": .string(status)]
                )
                if isStructured,
                    reportToolCallIDs.contains(details.toolCallId),
                    decodedOutcome == nil,
                    let outcome = Self.decodeOutcome(from: details, as: T.self)
                {
                    decodedOutcome = outcome
                    continuation.yield(.status("Outcome received."))
                } else {
                    continuation.yield(.status("\(name): \(status)."))
                }

            case .plan:
                logger.debug("\(harness) plan update")
                continuation.yield(.status("Plan updated."))

            case .usage(let usageUpdate):
                logger.debug(
                    "\(harness) usage update",
                    metadata: [
                        "used": .string("\(usageUpdate.used)"),
                        "size": .string("\(usageUpdate.size)"),
                    ]
                )
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
        logger.info(
            "\(harness) turn completed",
            metadata: ["stopReason": .string("\(response.stopReason)")]
        )

        if let outcome = decodedOutcome {
            return outcome
        }
        switch T.outputContract {
        case .plainText:
            // Plain-text outputs (String, ChatResponse) decode from the
            // collected stream text; no reporting tool is involved.
            return try? T(GeneratedContent(kind: .string(collectedText)))
        case .reportTool:
            return nil
        }
    }

    // MARK: - Prompt formatting

    /// Formats the full message list into a single ACP prompt text. System
    /// messages appear first so the agent receives its role and contract before
    /// the user/tool transcript.
    private static func formatPrompt(messages: [LLMMessage]) -> String {
        let systemMessages = messages.filter { $0.role == .system }
        let nonSystemMessages = messages.filter { $0.role != .system }

        var parts: [String] = []
        if !systemMessages.isEmpty {
            parts.append(systemMessages.map(\.content).joined(separator: "\n\n"))
        }
        if !nonSystemMessages.isEmpty {
            parts.append(formatCompactMessages(nonSystemMessages))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Formats a compact message transcript for the ACP agent.
    private static func formatCompactMessages(_ messages: [LLMMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .system:
                return message.content
            case .user:
                return "User: \(message.content)"
            case .assistant:
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    let calls = toolCalls.map {
                        "\($0.function.name): \($0.function.arguments)"
                    }.joined(separator: "\n")
                    return "Assistant (tool calls):\n\(calls)"
                }
                return "Assistant: \(message.content)"
            case .tool:
                return "Tool result: \(message.content)"
            }
        }.joined(separator: "\n\n")
    }

    /// Appends a concise instruction to call the dedicated outcome tool for
    /// structured assignment turns.
    private static func appendOutcomeInstruction<T: AgentOutput>(
        prompt: String,
        responseType: T.Type
    ) -> String {
        switch T.outputContract {
        case .plainText:
            return prompt
        case .reportTool(let name, _):
            return prompt + """


                Call the `\(name)` tool to report the outcome. \
                Do not reply with plain text.
                """
        }
    }

    // MARK: - Outcome decoding

    private static func expectedReportToolNames(for type: Any.Type) -> [String] {
        guard let outputType = type as? any AgentOutput.Type else { return [] }
        switch outputType.outputContract {
        case .plainText:
            return []
        case .reportTool(let name, _):
            return [name, "mcp__hail__\(name)"]
        }
    }

    private static func isReportOutcomeTool(name: String, expected: [String]) -> Bool {
        expected.contains(name)
    }

    private static func decodeOutcome<T: Codable & Generable & Sendable>(
        from toolCall: ToolCallUpdate,
        as type: T.Type
    ) -> T? {
        guard let rawInput = toolCall.rawInput else { return nil }
        return decodeOutcome(from: rawInput, as: type)
    }

    private static func decodeOutcome<T: Codable & Generable & Sendable>(
        from details: ToolCallUpdateDetails,
        as type: T.Type
    ) -> T? {
        guard let rawInput = details.rawInput else { return nil }
        return decodeOutcome(from: rawInput, as: type)
    }

    private static func decodeOutcome<T: Codable & Generable & Sendable>(
        from rawInput: AnyCodable,
        as type: T.Type
    ) -> T? {
        // First try a direct Codable decode; this is the common path for
        // report-tool arguments sent by the agent.
        if let direct = decodeDirect(from: rawInput, as: type) {
            return direct
        }
        // Fall back to the GeneratedContent path for providers that shape
        // arguments differently.
        do {
            let data = try JSONEncoder().encode(rawInput)
            guard let json = String(data: data, encoding: .utf8) else { return nil }
            let content = try GeneratedContent(json: json)
            return try T(content)
        } catch {
            logger.debug(
                "Failed to decode tool arguments as structured outcome",
                metadata: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    private static func decodeDirect<T: Codable & Sendable>(
        from rawInput: AnyCodable,
        as type: T.Type
    ) -> T? {
        do {
            let data = try JSONEncoder().encode(rawInput)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.debug(
                "Direct tool-argument decode failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }
}

// MARK: - SessionOwningEndpoint

extension ACPModelEndpoint: SessionOwningEndpoint {
    var currentSessionID: SessionID? {
        get async {
            await session.currentSessionID
        }
    }

    func stream<T: AgentOutput>(
        messages: [LLMMessage],
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        stream(
            messages: messages, turnDelta: turnDelta, authority: authority, tools: tools,
            responseType: responseType)
    }

    func terminateSession() async {
        await session.terminate()
    }
}
