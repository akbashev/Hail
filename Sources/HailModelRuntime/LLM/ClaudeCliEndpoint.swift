import AnyLanguageModel
import HailCore
import Logging
import ScopedEffect
import Subprocess
import Synchronization
import System

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let claudeLogger = Logger(label: "ClaudeCliEndpoint")

/// Mutable session state shared across turns of one cached endpoint instance.
/// `ModelRouter` caches endpoints per (model, agent, context), so this box
/// lives exactly as long as the cache entry — the session id is re-persisted
/// to the agent journal separately (crash recovery resumes with `--resume`).
private final class ClaudeSessionState: Sendable {
    struct State: Sendable {
        var sessionID: SessionID?
        var identity: SessionIdentity?
        var memorySnapshot: String?
    }

    private let state = Mutex(State())

    var snapshot: State {
        state.withLock { $0 }
    }

    func setSessionID(_ id: SessionID?) {
        state.withLock { $0.sessionID = id }
    }

    func setMemorySnapshot(_ memory: String?) {
        state.withLock { $0.memorySnapshot = memory }
    }

    /// Primes the box with a journaled session to resume on the first turn.
    func prime(id: SessionID, identity: SessionIdentity) {
        state.withLock {
            $0.sessionID = id
            $0.identity = identity
        }
    }

    /// Drops the current session and re-arms identity/memory for the next
    /// (cold) turn.
    func reset(identity: SessionIdentity?, memorySnapshot: String?) {
        state.withLock {
            $0.sessionID = nil
            $0.identity = identity
            $0.memorySnapshot = memorySnapshot
        }
    }
}

/// A local Claude Code–backed model endpoint that drives the native `claude`
/// CLI directly — no ACP adapter, no Node.
///
/// Like ``CodexAppServerEndpoint``, this endpoint lets Claude Code run its *own*
/// agentic loop. Kimi uses ACP; Claude uses its native stream-JSON protocol.
/// Tools stay
/// enabled, the Hail MCP server is passed in (`--mcp-config`) so host tools
/// `document`, `hail_context`, and the report tools are real, and Hail
/// harvests the structured outcome from the `report_*` tool call in the
/// `stream-json` output. This is the integration Claude Code is built for, using
/// the plain `claude` binary and the user's existing login.
public struct ClaudeCliEndpoint: ModelEndpoint {
    public let model: String
    public let executionPolicy: AgentExecutionPolicy
    public let reasoningEffort: ReasoningEffort?

    private let workingDirectory: String
    private let agentID: String?
    private let contextLabel: String?
    private let mcpServerConfiguration: MCPServerConfiguration?
    private let executablePath: String
    /// The authority the `claude` process spawn is scoped against.
    private let authority: any Authority
    private let sessionState = ClaudeSessionState()

    /// Stall ceiling for one `claude -p` turn: the subprocess is awaited with
    /// no output-based liveness signal Hail can trust, so a hung process is
    /// failed (and cancelled) once it exceeds this budget instead of blocking
    /// the turn forever. Defaults to 30 minutes like the ACP/Codex ceilings;
    /// `HAIL_CLAUDE_MAX_STALL_TIMEOUT` (seconds) overrides.
    private let maxStallDuration: TimeInterval

    public init(
        model: String,
        workingDirectory: String,
        agentID: String? = nil,
        contextLabel: String? = nil,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        executablePath: String = "/usr/bin/env",
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        maxStallDuration: TimeInterval? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) throws(ModelRouterError) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw .invalidRoute(.missingModel(AgentModelProvider.claude.rawValue))
        }
        self.model = model
        self.executionPolicy = executionPolicy
        self.reasoningEffort = reasoningEffort
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.contextLabel = contextLabel
        self.mcpServerConfiguration = mcpServerConfiguration
        self.executablePath = executablePath
        self.authority = authority ?? FullAuthority()
        self.maxStallDuration = try ProcessEnvironment.timeInterval(
            override: maxStallDuration,
            from: "HAIL_CLAUDE_MAX_STALL_TIMEOUT",
            default: 1800
        )
        if let resumeSession {
            sessionState.prime(id: resumeSession.id, identity: resumeSession.identity)
        }
    }

    // MARK: - ModelEndpoint

    public func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>> {
        AsyncStream(ModelEvent<String>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Claude CLI is running."))
                    let prompt = Self.formatPrompt(messages: messages, reportToolName: nil)
                    let outcome = try await runTurn(
                        prompt: prompt,
                        reportToolNames: [],
                        authority: authority,
                        onNarration: { Self.forward($0, to: continuation) }
                    )
                    if outcome.isError {
                        continuation.yield(
                            .failed(ModelEndpointError.requestFailed(outcome.errorText ?? "claude -p failed")))
                    } else {
                        continuation.yield(.generated(outcome.finalText))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch let modelError as ModelEndpointError {
                    continuation.yield(.failed(modelError))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        switch T.outputContract {
        case .plainText:
            return streamPlainText(messages: messages, responseType: T.self)
        case .reportTool(let name, _):
            return streamStructured(messages: messages, reportToolName: name, responseType: T.self)
        }
    }

    private func streamPlainText<T: AgentOutput>(
        messages: [LLMMessage],
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Claude CLI is running."))
                    let prompt = Self.formatPrompt(messages: messages, reportToolName: nil)
                    let outcome = try await runTurn(
                        prompt: prompt,
                        reportToolNames: [],
                        authority: authority,
                        onNarration: { Self.forward($0, to: continuation) }
                    )
                    guard !outcome.isError else {
                        continuation.yield(
                            .failed(ModelEndpointError.requestFailed(outcome.errorText ?? "claude -p failed")))
                        continuation.finish()
                        return
                    }
                    if let value = CLIEndpointSupport.decodeOutcome(
                        fromText: outcome.finalText, as: T.self, logger: claudeLogger)
                    {
                        continuation.yield(.generated(value))
                    } else {
                        continuation.yield(
                            .failed(ModelEndpointError.decodingError("Claude CLI output is not \(T.self)")))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch let modelError as ModelEndpointError {
                    continuation.yield(.failed(modelError))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamStructured<T: AgentOutput>(
        messages: [LLMMessage],
        reportToolName: String,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Claude CLI is running."))
                    let prompt = Self.formatPrompt(messages: messages, reportToolName: reportToolName)
                    let reportToolNames = [reportToolName, "mcp__hail__\(reportToolName)"]
                    let outcome = try await runTurn(
                        prompt: prompt,
                        reportToolNames: reportToolNames,
                        authority: authority,
                        onNarration: { Self.forward($0, to: continuation) }
                    )
                    guard !outcome.isError else {
                        continuation.yield(
                            .failed(ModelEndpointError.requestFailed(outcome.errorText ?? "claude -p failed")))
                        continuation.finish()
                        return
                    }
                    // The structured outcome is the argument object of the
                    // report tool the agent called inside its own loop.
                    if let reportJSON = outcome.reportJSON,
                        let value = CLIEndpointSupport.decodeOutcome(
                            fromJSON: reportJSON, as: T.self, logger: claudeLogger)
                    {
                        continuation.yield(.status("Outcome received."))
                        continuation.yield(.generated(value))
                    } else {
                        continuation.yield(
                            .failed(
                                ModelEndpointError.invalidResponse(
                                    "Claude finished without calling \(reportToolName)."
                                )))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch let modelError as ModelEndpointError {
                    continuation.yield(.failed(modelError))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Turn execution

    private enum Narration {
        case text(String)
        case thinking(String)
        case status(String)
    }

    private struct TurnResult {
        var finalText: String
        var reportJSON: String?
        var isError: Bool
        var errorText: String?
        var sessionID: String?
        /// The subprocess's stderr, captured regardless of exit status. Claude
        /// CLI failures (a resume miss, a bad argument, a crash) often print
        /// only to stderr with no `stream-json` output at all, leaving
        /// `errorText` empty — this is what actually explains those failures.
        var stderrText: String?
    }

    private static func forward<Output>(
        _ narration: Narration,
        to continuation: AsyncStream<ModelEvent<Output>>.Continuation
    ) {
        switch narration {
        case .text(let text): continuation.yield(.text(text))
        case .thinking(let text): continuation.yield(.thinking(text))
        case .status(let status): continuation.yield(.status(status))
        }
    }

    /// Mutable accumulator folded over the `stream-json` line stream.
    private struct ParseState {
        var assistantText = ""
        var resultText: String?
        var reportJSON: String?
        var isError = false
        var errorText: String?
        var sessionID: String?

        var result: TurnResult {
            TurnResult(
                finalText: resultText ?? assistantText,
                reportJSON: reportJSON,
                isError: isError,
                errorText: errorText,
                sessionID: sessionID
            )
        }
    }

    /// Runs one `claude -p` turn, reading `stream-json` output incrementally so
    /// narration (text/thinking/tool status) reaches the caller live as Claude
    /// works, rather than only after the whole turn finishes. Also harvests the
    /// final result text and, for structured turns, the report tool call.
    /// `authority` scopes the process spawn; always the endpoint's creation
    /// authority — per-turn lanes never gate the spawn (see ``sessionStream``).
    /// The subprocess wait is bounded by `maxStallDuration`: a hung `claude -p`
    /// throws `TimeoutError` (failing the turn) instead of blocking forever.
    private func runTurn(
        prompt: String,
        resumeSessionID: String? = nil,
        reportToolNames: [String],
        authority: any Authority,
        onNarration: @escaping @Sendable (Narration) -> Void
    ) async throws -> TurnResult {
        let mcpConfig = await mcpConfigJSON()
        claudeLogger.info(
            "Running claude -p (MCP-native)",
            metadata: [
                "model": .string(model),
                "agentID": .string(agentID ?? "-"),
                "contextLabel": .string(contextLabel ?? "-"),
                "workingDirectory": .string(workingDirectory),
                "mcp": .string(mcpConfig == nil ? "none" : (mcpServerConfiguration?.name ?? "host")),
            ]
        )

        let claudeArgs = claudeArguments(mcpConfig: mcpConfig, resumeSessionID: resumeSessionID)
        // Spawning `claude` is a process effect, checked against the
        // endpoint's authority before the subprocess exists. The timeout
        // wrapper cancels the subprocess task at the stall ceiling; the
        // error surfaces as `TimeoutError`.
        let execution = try await withTimeout(seconds: maxStallDuration) {
            try await withEffect(
                ProcessEffect(executable: executablePath, arguments: claudeArgs, cwd: workingDirectory),
                authority: authority
            ) { _ in
                try await run(
                    .path(FilePath(executablePath)),
                    arguments: .init(claudeArgs),
                    environment: .inherit.updating(hailEnvironment),
                    workingDirectory: FilePath(workingDirectory),
                    // `.array`, not `.data`: swift-subprocess's Data input bridges to
                    // a borrowed RawSpan whose owner can die before the async write
                    // completes — observed as garbage bytes on the child's stdin.
                    input: .array([UInt8](prompt.utf8)),
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    // Drained concurrently with stdout: the child can fill the
                    // stderr pipe while we're blocked reading stdout (or vice
                    // versa), so reading them sequentially risks a deadlock.
                    async let stderrBytes: [UInt8] = {
                        var buffer: [UInt8] = []
                        for try await chunk in execution.standardError {
                            buffer.append(contentsOf: Data(buffer: chunk))
                        }
                        return buffer
                    }()

                    var state = ParseState()
                    var pending: [UInt8] = []
                    for try await chunk in execution.standardOutput {
                        pending.append(contentsOf: Data(buffer: chunk))
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = Data(pending[..<newline])
                            pending.removeSubrange(...newline)
                            Self.consume(
                                line: line, reportToolNames: reportToolNames, onNarration: onNarration, into: &state)
                        }
                    }
                    if !pending.isEmpty {
                        Self.consume(
                            line: Data(pending), reportToolNames: reportToolNames, onNarration: onNarration,
                            into: &state)
                    }
                    var result = state.result
                    let stderrData = try await stderrBytes
                    if !stderrData.isEmpty {
                        result.stderrText = String(decoding: stderrData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return result
                }
            }
        }

        let turn = execution.closureResult
        guard Self.exitCode(from: execution.terminationStatus) == 0 else {
            let reason = [turn.finalText, turn.stderrText]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " | ")
            return TurnResult(
                finalText: "", reportJSON: nil, isError: true,
                errorText: reason.isEmpty ? "claude -p failed" : reason,
                sessionID: turn.sessionID, stderrText: turn.stderrText)
        }
        return turn
    }

    /// Parses one `stream-json` event line, forwarding narration and folding
    /// the result text / report tool call into `state`.
    private static func consume(
        line: Data,
        reportToolNames: [String],
        onNarration: @Sendable (Narration) -> Void,
        into state: inout ParseState
    ) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = event["type"] as? String
        else { return }

        // Every event carries the session id; capturing it here keeps the
        // endpoint's session state current for later `--resume` turns.
        if let sessionID = event["session_id"] as? String {
            state.sessionID = sessionID
        }

        switch type {
        case "assistant":
            guard let message = event["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String {
                        state.assistantText += text
                        onNarration(.text(text))
                    }
                case "thinking":
                    if let text = block["thinking"] as? String {
                        onNarration(.thinking(text))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    if reportToolNames.contains(name),
                        let input = block["input"],
                        JSONSerialization.isValidJSONObject(input),
                        let inputData = try? JSONSerialization.data(withJSONObject: input),
                        let json = String(data: inputData, encoding: .utf8)
                    {
                        state.reportJSON = json
                        onNarration(.status("Reporting outcome."))
                    } else {
                        onNarration(.status("Calling \(name)."))
                    }
                default:
                    break
                }
            }
        case "result":
            if let error = event["is_error"] as? Bool, error {
                state.isError = true
                state.errorText = event["result"] as? String
            } else if let result = event["result"] as? String {
                state.resultText = result
            }
        default:
            break
        }
    }

    // MARK: - Command + config

    private func claudeArguments(mcpConfig: String?, resumeSessionID: String? = nil) -> [String] {
        var arguments = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            // Non-interactive auto-approval, matching how the Kimi harness runs
            // (`-y --auto`). This does not force API-key auth — only `--bare` does —
            // so the user's `claude` login is still used.
            "--dangerously-skip-permissions",
        ]
        if let resumeSessionID {
            // Warm session: continue the CLI-owned conversation instead of
            // resending the transcript. The session id is stable across
            // resumed turns (no --fork-session), so it is persisted once.
            arguments.append(contentsOf: ["--resume", resumeSessionID])
        }
        if let mcpConfig {
            // Only trust the Hail server, not the user's other project MCP
            // configs.
            arguments.append(contentsOf: ["--strict-mcp-config", "--mcp-config", mcpConfig])
        }
        arguments.append(contentsOf: ["--model", model])
        if let reasoningEffort {
            arguments.append(contentsOf: ["--effort", reasoningEffort.rawValue])
        }
        return arguments
    }

    /// Builds an inline `--mcp-config` JSON that registers the Hail MCP
    /// server supplied by the host, scoped to this agent/context via env — the
    /// same server the kimi ACP session wires up.
    private func mcpConfigJSON() async -> String? {
        guard let configuration = mcpServerConfiguration else { return nil }
        let env = configuration.environment(agentID: agentID, context: contextLabel)
        let config: [String: Any] = [
            "mcpServers": [
                configuration.name: [
                    "command": configuration.command,
                    "args": configuration.arguments,
                    "env": env,
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private var hailEnvironment: [Environment.Key: String?] {
        var env: [Environment.Key: String?] = [:]
        for (key, value) in mcpServerConfiguration?.environment(
            agentID: agentID,
            context: contextLabel
        ) ?? [:] {
            env[Environment.Key(stringLiteral: key)] = value
        }
        return env
    }

    // MARK: - Prompt

    /// Formats the transcript into a single prompt (system context first), and
    /// appends an instruction to finish by calling the report tool — the agent
    /// does the work with its own tools, then reports the structured outcome.
    private static func formatPrompt(messages: [LLMMessage], reportToolName: String?) -> String {
        let systemText = messages.filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let transcript = messages.filter { $0.role != .system }
            .map { message -> String in
                switch message.role {
                case .system: return message.content
                case .user: return "User: \(message.content)"
                case .assistant: return "Assistant: \(message.content)"
                case .tool: return "Tool result: \(message.content)"
                }
            }
            .joined(separator: "\n\n")

        var parts: [String] = []
        if !systemText.isEmpty { parts.append(systemText) }
        if !transcript.isEmpty { parts.append(transcript) }
        if let reportToolName {
            parts.append(
                "Do the actual work using your tools (read the provided context, inspect and edit the "
                    + "codebase, run commands as needed). When the assignment is complete, call the "
                    + "`\(reportToolName)` tool with the structured outcome.")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func exitCode(from status: TerminationStatus) -> Int {
        switch status {
        case .exited(let code):
            return Int(code)
        #if !os(Windows)
            case .signaled(let signal):
                return Int(signal) + 128
        #endif
        }
    }
}

// MARK: - SessionOwningEndpoint

extension ClaudeCliEndpoint: SessionOwningEndpoint {
    public var currentSessionID: SessionID? {
        get async {
            sessionState.snapshot.sessionID
        }
    }

    /// The turn's lane is accepted for protocol conformance but not forwarded:
    /// this endpoint has no model-facing effect surface of its own (fs/terminal
    /// reach Hail through the MCP tools, not through a delegate), and the
    /// process spawn is infrastructure scoped against the creation authority.
    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        let reportToolName: String?
        switch T.outputContract {
        case .plainText:
            reportToolName = nil
        case .reportTool(let name, _):
            reportToolName = name
        }
        return sessionStream(
            messages: messages,
            delta: turnDelta,
            reportToolName: reportToolName,
            responseType: T.self
        )
    }

    /// Streams one turn through the CLI-owned session: a warm session is
    /// resumed with only the turn's delta; a cold start or an identity change
    /// runs a fresh turn with the full bootstrap transcript. Any failure
    /// clears the session id ("reset on doubt"), so the next turn bootstraps
    /// from the journal. The turn's lane deliberately does *not* reach the
    /// `claude` spawn: the spawn is endpoint infrastructure (fixed binary +
    /// arguments), not a model-decided effect, so it is always scoped against
    /// the endpoint's creation authority — a deny-everything lane must not
    /// make the turn itself impossible.
    private func sessionStream<T: AgentOutput>(
        messages: [LLMMessage],
        delta turnDelta: TurnDelta,
        reportToolName: String?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        AsyncStream(ModelEvent<T>.self) { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Claude CLI is running."))

                    let memorySnapshot =
                        turnDelta.workingMemory.isEmpty
                        ? nil
                        : "Current working memory (supersedes any earlier memory in this session):\n"
                            + turnDelta.workingMemory.map { "- \($0)" }.joined(separator: "\n")

                    let prompt: String
                    let resumeID: SessionID?
                    let snapshot = sessionState.snapshot
                    if let sessionID = snapshot.sessionID, snapshot.identity == turnDelta.sessionIdentity {
                        var parts: [String] = []
                        if let memorySnapshot, memorySnapshot != snapshot.memorySnapshot {
                            parts.append(memorySnapshot)
                            sessionState.setMemorySnapshot(memorySnapshot)
                        }
                        parts.append(
                            Self.formatPrompt(messages: turnDelta.messages, reportToolName: reportToolName)
                        )
                        prompt = parts.joined(separator: "\n\n")
                        resumeID = sessionID
                        claudeLogger.info(
                            "Resuming claude session with warm delta",
                            metadata: [
                                "agentID": .string(agentID ?? "-"),
                                "sessionID": .string(sessionID.rawValue),
                                "deltaLength": .string("\(prompt.count)"),
                            ]
                        )
                    } else {
                        sessionState.reset(
                            identity: turnDelta.sessionIdentity,
                            memorySnapshot: memorySnapshot
                        )
                        prompt = Self.formatPrompt(messages: messages, reportToolName: reportToolName)
                        resumeID = nil
                        claudeLogger.info(
                            "Bootstrapping fresh claude session with full transcript",
                            metadata: [
                                "agentID": .string(agentID ?? "-"),
                                "bootstrapLength": .string("\(prompt.count)"),
                            ]
                        )
                    }

                    let reportToolNames = reportToolName.map { [$0, "mcp__hail__\($0)"] } ?? []
                    var outcome = try await runTurn(
                        prompt: prompt,
                        resumeSessionID: resumeID?.rawValue,
                        reportToolNames: reportToolNames,
                        authority: authority,
                        onNarration: { Self.forward($0, to: continuation) }
                    )

                    if outcome.isError, resumeID != nil {
                        // Resume miss (session expired, GC'd, or the CLI was
                        // upgraded): drop it and fall back to a full bootstrap.
                        claudeLogger.warning(
                            "claude --resume failed; falling back to bootstrap",
                            metadata: [
                                "agentID": .string(agentID ?? "-"),
                                "sessionID": .string(resumeID?.rawValue ?? "-"),
                                "reason": .string(outcome.errorText ?? "-"),
                            ]
                        )
                        sessionState.setSessionID(nil)
                        outcome = try await runTurn(
                            prompt: Self.formatPrompt(messages: messages, reportToolName: reportToolName),
                            resumeSessionID: nil,
                            reportToolNames: reportToolNames,
                            authority: authority,
                            onNarration: { Self.forward($0, to: continuation) }
                        )
                    }

                    guard !outcome.isError else {
                        sessionState.setSessionID(nil)
                        continuation.yield(
                            .failed(ModelEndpointError.requestFailed(outcome.errorText ?? "claude -p failed")))
                        continuation.finish()
                        return
                    }
                    if let sessionID = outcome.sessionID {
                        sessionState.setSessionID(SessionID(sessionID))
                    }

                    if let reportToolName {
                        guard let reportJSON = outcome.reportJSON,
                            let value = CLIEndpointSupport.decodeOutcome(
                                fromJSON: reportJSON, as: T.self, logger: claudeLogger)
                        else {
                            continuation.yield(
                                .failed(
                                    ModelEndpointError.invalidResponse(
                                        "Claude finished without calling \(reportToolName)."
                                    )))
                            continuation.finish()
                            return
                        }
                        continuation.yield(.status("Outcome received."))
                        continuation.yield(.generated(value))
                    } else if let value = CLIEndpointSupport.decodeOutcome(
                        fromText: outcome.finalText, as: T.self, logger: claudeLogger)
                    {
                        continuation.yield(.generated(value))
                    } else {
                        continuation.yield(
                            .failed(ModelEndpointError.decodingError("Claude CLI output is not \(T.self)")))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(ModelEndpointError.cancelled))
                    continuation.finish()
                } catch {
                    sessionState.setSessionID(nil)
                    continuation.yield(.failed(ModelEndpointError.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
