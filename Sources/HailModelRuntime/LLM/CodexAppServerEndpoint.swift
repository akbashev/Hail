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
    public let reasoningEffort: ReasoningEffort?

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
        maxStallDuration: TimeInterval? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) throws(ModelRouterError) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw .invalidModel(.missingID(AgentModelProvider.codex.rawValue))
        }
        self.model = model
        self.executionPolicy = executionPolicy
        self.reasoningEffort = reasoningEffort
        self.session = try CodexAppServerSession(
            model: model,
            workingDirectory: workingDirectory,
            agentID: agentID,
            contextLabel: contextLabel,
            mcpServerConfiguration: mcpServerConfiguration,
            executionPolicy: executionPolicy,
            reasoningEffort: reasoningEffort,
            executablePath: executablePath,
            resumeSession: resumeSession,
            authority: authority ?? FullAuthority(),
            maxStallDuration: maxStallDuration
        )
    }

    public func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        return makeStream(
            entries: request.entries,
            delta: nil,
            sessionIdentity: nil,
            authority: authority,
            generating: outputType,
            purpose: purpose
        )
    }

    private func makeStream<Output>(
        entries: [Transcript.Entry],
        delta: [Transcript.Entry]?,
        sessionIdentity: SessionIdentity?,
        authority: (any Authority)?,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        let structured = Output.self != String.self
        return AsyncStream(ModelEvent<Output>.self) { continuation in
            let task = Task {
                do {
                    let schema =
                        structured
                        ? try CLIEndpointSupport.finalOutputSchema(for: Output.self)
                        : nil
                    continuation.yield(.activity(.status(GeneratedContent("Codex is running."))))
                    let result = try await session.runTurn(
                        fullPrompt: Self.formatPrompt(
                            entries: entries,
                            structured: structured
                        ),
                        deltaPrompt: delta.map { Self.formatPrompt(entries: $0, structured: structured) },
                        identity: sessionIdentity,
                        outputSchema: schema,
                        turnAuthority: authority,
                        onNarration: { narration in
                            switch narration {
                            case .narrationDelta(let text):
                                continuation.yield(.activity(.narrationDelta(GeneratedContent(text))))
                            case .reasoningDelta(let text):
                                continuation.yield(.activity(.reasoningDelta(GeneratedContent(text))))
                            case .status(let text): continuation.yield(.activity(.status(GeneratedContent(text))))
                            }
                        }
                    )
                    let value: Output? =
                        structured
                        ? CLIEndpointSupport.decodeOutcome(
                            fromJSON: result, as: Output.self, logger: codexLogger)
                        : CLIEndpointSupport.decodeOutcome(
                            fromText: result, as: Output.self, logger: codexLogger)
                    guard let value else {
                        continuation.yield(.failed(.decodingError("Codex output is not \(Output.self)")))
                        continuation.finish()
                        return
                    }
                    if structured { continuation.yield(.activity(.status(GeneratedContent("Outcome received.")))) }
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

    private static func formatPrompt(entries: [Transcript.Entry], structured: Bool) -> String {
        let rendered = entries.map(Self.text)
        let transcript = rendered.joined(separator: "\n\n")
        let system = entries.compactMap { entry -> String? in
            guard case .instructions = entry else { return nil }
            return Self.text(entry)
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

    private static func text(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions(let value): return render(value.segments)
        case .prompt(let value): return "User: \(render(value.segments))"
        case .response(let value): return "Assistant: \(render(value.segments))"
        case .toolCalls(let value): return "Assistant tool calls: \(value.id)"
        case .toolOutput(let value): return "Tool result: \(render(value.segments))"
        case .reasoning(let value): return "Assistant reasoning: \(render(value.segments))"
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
}

extension CodexAppServerEndpoint: SessionOwningEndpoint {
    public var currentSessionID: SessionID? {
        get async { await session.currentSessionID }
    }

    public func stream<Input, Output>(
        request: ModelRequest<Input>,
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [AnyTool],
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        return makeStream(
            entries: request.entries,
            delta: turnDelta.current.entries,
            sessionIdentity: turnDelta.sessionIdentity,
            authority: authority,
            generating: outputType,
            purpose: purpose
        )
    }

    public func terminateSession() async {
        await session.terminate()
    }
}
