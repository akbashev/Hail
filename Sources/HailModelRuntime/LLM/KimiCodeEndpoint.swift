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

    public func stream(
        input: ModelInput,
        tools: [ToolDefinition]?
    ) -> AsyncStream<ModelEvent<String>> {
        core.stream(input: input, tools: tools)
    }

    public func stream<T: AgentOutput>(
        input: ModelInput,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        core.stream(input: input, tools: tools, responseType: T.self)
    }
}

extension KimiCodeEndpoint: SessionOwningEndpoint {
    public var currentSessionID: SessionID? {
        get async {
            await core.currentSessionID
        }
    }

    public func stream<T: AgentOutput>(
        input: ModelInput,
        delta turnDelta: TurnDelta,
        authority: any Authority,
        tools: [ToolDefinition]?,
        responseType: T.Type
    ) -> AsyncStream<ModelEvent<T>> {
        core.stream(
            input: input, delta: turnDelta, authority: authority, tools: tools, responseType: T.self)
    }

    public func terminateSession() async {
        await core.terminateSession()
    }
}
