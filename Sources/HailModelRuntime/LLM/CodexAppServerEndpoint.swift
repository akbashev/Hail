import AnyLanguageModel
import HailCore
import Logging
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let codexLogger = Logger(label: "CodexAppServerEndpoint")

/// A local Codex endpoint backed by one long-lived native App Server process.
///
/// The process is the live session cache: it is initialized once, owns one
/// Codex thread, and accepts many `turn/start` requests. The thread id is also
/// journaled so a replacement process can resume after agent reactivation or a
/// crash. A missing durable thread falls back to a cold bootstrap from Hail's
/// event-sourced transcript.
public struct CodexAppServerEndpoint: ModelEndpoint {
    public let model: String
    public let executionPolicy: AgentExecutionPolicy

    private let session: CodexAppServerSession

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
        maxStallDuration: TimeInterval? = nil
    ) throws(ModelRouterError) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw .invalidRoute(.missingModel("codex"))
        }
        self.model = model
        self.executionPolicy = executionPolicy
        self.session = try CodexAppServerSession(
            model: model,
            workingDirectory: workingDirectory,
            agentID: agentID,
            contextLabel: contextLabel,
            mcpServerConfiguration: mcpServerConfiguration,
            executionPolicy: executionPolicy,
            executablePath: executablePath,
            resumeSession: resumeSession,
            authority: authority ?? FullAuthority(),
            maxStallDuration: maxStallDuration
        )
    }

    public func stream(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?
    ) -> AsyncStream<ModelEvent<String>> {
        _ = tools
        return makeStream(
            messages: messages,
            delta: nil,
            sessionIdentity: nil,
            workingMemory: [],
            authority: nil,
            responseType: String.self
        )
    }

    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        _ = tools
        return makeStream(
            messages: messages,
            delta: nil,
            sessionIdentity: nil,
            workingMemory: [],
            authority: nil,
            responseType: responseType
        )
    }

    private func makeStream<T: AgentOutput>(
        messages: [LLMMessage],
        delta: [LLMMessage]?,
        sessionIdentity: SessionIdentity?,
        workingMemory: [String],
        authority: (any Authority)?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        let structured: Bool =
            switch T.outputContract {
            case .plainText: false
            case .reportTool: true
            }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let schema =
                        structured
                        ? try CLIEndpointSupport.finalOutputSchema(for: T.self)
                        : nil
                    continuation.yield(.status("Codex is running."))
                    let result = try await session.runTurn(
                        fullPrompt: Self.formatPrompt(messages: messages, structured: structured),
                        deltaPrompt: delta.map { Self.formatPrompt(messages: $0, structured: structured) },
                        identity: sessionIdentity,
                        memorySnapshot: Self.memorySnapshot(workingMemory),
                        outputSchema: schema,
                        turnAuthority: authority,
                        onNarration: { narration in
                            switch narration {
                            case .text(let text): continuation.yield(.text(text))
                            case .thinking(let text): continuation.yield(.thinking(text))
                            case .status(let text): continuation.yield(.status(text))
                            }
                        }
                    )
                    let value: T? =
                        structured
                        ? CLIEndpointSupport.decodeOutcome(
                            fromJSON: result, as: T.self, logger: codexLogger)
                        : CLIEndpointSupport.decodeOutcome(
                            fromText: result, as: T.self, logger: codexLogger)
                    guard let value else {
                        continuation.yield(.failed(.decodingError("Codex output is not \(T.self)")))
                        continuation.finish()
                        return
                    }
                    if structured { continuation.yield(.status("Outcome received.")) }
                    continuation.yield(.generated(value))
                    continuation.finish()
                } catch CodexSessionError.cancelled {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch let error as ModelEndpointError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.requestFailed(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func memorySnapshot(_ memory: [String]) -> String? {
        guard !memory.isEmpty else { return nil }
        return "Current working memory (supersedes any earlier memory in this session):\n"
            + memory.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func formatPrompt(messages: [LLMMessage], structured: Bool) -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let transcript = messages.filter { $0.role != .system }.map { message -> String in
            switch message.role {
            case .system: return message.content
            case .user: return "User: \(message.content)"
            case .assistant: return "Assistant: \(message.content)"
            case .tool: return "Tool result: \(message.content)"
            }
        }.joined(separator: "\n\n")
        var parts = [system, transcript].filter { !$0.isEmpty }
        parts.append(
            "Do the actual work using your tools. Host tools may be available through MCP. Work only inside the configured workspace."
        )
        if structured {
            parts.append(
                "When finished, return the final structured result directly. The output schema is enforced by the runtime."
            )
        }
        return parts.joined(separator: "\n\n")
    }
}

extension CodexAppServerEndpoint: SessionOwningEndpoint {
    public var currentSessionID: SessionID? {
        get async { await session.currentSessionID }
    }

    public func stream<T: AgentOutput>(
        messages: [LLMMessage],
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [LLMToolSchema]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        _ = tools
        return makeStream(
            messages: messages,
            delta: turnDelta.messages,
            sessionIdentity: turnDelta.sessionIdentity,
            workingMemory: turnDelta.workingMemory,
            authority: authority,
            responseType: responseType
        )
    }

    public func terminateSession() async {
        await session.terminate()
    }
}
