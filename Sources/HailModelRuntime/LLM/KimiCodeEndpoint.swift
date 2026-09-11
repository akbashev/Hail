import AnyLanguageModel
import HailCore
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A ``ModelEndpoint`` that drives the local `kimi-code` CLI over ACP.
///
/// A thin configuration of the shared ``ACPModelEndpoint``: it only decides
/// which command launches the agent (`kimi acp`, with auto-approval flags when
/// the execution policy allows) and delegates all ACP↔Hail mapping to the
/// core.
public struct KimiCodeEndpoint: ModelEndpoint {
    private let core: ACPModelEndpoint

    public var model: String { core.model }
    public var executionPolicy: AgentExecutionPolicy { core.executionPolicy }

    public init(
        model: String,
        workingDirectory: String,
        agentID: String? = nil,
        contextLabel: String? = nil,
        mcpServerConfiguration: MCPServerConfiguration? = nil,
        executionPolicy: AgentExecutionPolicy = .autonomousWorkspace,
        agentPath: String = "/usr/bin/env",
        resumeSession: ModelSessionResume? = nil,
        authority: (any Authority)? = nil,
        // `-y`/`--yolo` and `--auto` auto-approves kimi-code's own permission
        // prompts so the agent can run non-interactively as a Hail subprocess.
        agentArguments: [String]? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) throws(ModelRouterError) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw .invalidModel(.missingID(AgentModelProvider.kimiCode.rawValue))
        }
        self.core = ACPModelEndpoint(
            harness: AgentModelProvider.kimiCode.rawValue,
            model: model,
            executionPolicy: executionPolicy,
            session: try ACPSession(
                model: model,
                workingDirectory: workingDirectory,
                agentID: agentID,
                contextLabel: contextLabel,
                mcpServerConfiguration: mcpServerConfiguration,
                agentPath: agentPath,
                agentArguments: agentArguments ?? Self.defaultAgentArguments(for: executionPolicy),
                reasoningEffort: reasoningEffort,
                resumeSession: resumeSession,
                authority: authority
            )
        )
    }

    private static func defaultAgentArguments(for executionPolicy: AgentExecutionPolicy) -> [String] {
        guard executionPolicy.approvalPolicy == .never else {
            return ["kimi", "acp"]
        }
        return ["kimi", "-y", "--auto", "acp"]
    }

    public func stream<Input, Output>(
        input: Input,
        entries: [Transcript.Entry],
        tools: [AnyTool],
        authority: any Authority,
        generating outputType: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where
        Input: Sendable,
        Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable
    {
        core.stream(
            input: input, entries: entries, tools: tools, authority: authority,
            generating: outputType, purpose: purpose
        )
    }
}

extension KimiCodeEndpoint: SessionOwningEndpoint {
    public var currentSessionID: SessionID? {
        get async {
            await core.currentSessionID
        }
    }

    public func stream<Input, Output>(
        input: Input,
        entries: [Transcript.Entry],
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
        core.stream(
            input: input, entries: entries, delta: turnDelta, authority: authority, tools: tools,
            generating: outputType, purpose: purpose)
    }

    public func terminateSession() async {
        await core.terminateSession()
    }
}
