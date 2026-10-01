import AnyLanguageModel
import ScopedEffect

public struct ToolExecution: Sendable {
    public let result: ToolResult

    public init(result: ToolResult) {
        self.result = result
    }
}

public actor ToolRegistry: Sendable {
    private var tools: [String: AnyTool] = [:]

    /// The authority effect-tools are checked against at dispatch. Defaults
    /// to ``FullAuthority`` (everything open); narrower authorities are
    /// derived per agent/lane by the runtime plugin's provider.
    public let authority: any Authority

    public init(authority: any Authority = FullAuthority()) {
        self.authority = authority
    }

    /// Registers every tool through the same authority-aware erased witness.
    public func register<T: Tool>(_ tool: T) {
        tools[tool.name] = AnyTool(tool)
    }

    public func tool(named name: String) -> AnyTool? {
        tools[name]
    }

    public func allTools() -> [AnyTool] {
        tools.values.sorted { $0.name < $1.name }
    }

    public func schemas(forTools toolNames: [String]? = nil) -> [ToolDefinition] {
        if let toolNames {
            let allowed = Set(toolNames)
            return tools.values
                .filter { allowed.contains($0.name) }
                .map { $0.schema }
                .sorted { $0.name < $1.name }
        }
        return tools.values
            .map { $0.schema }
            .sorted { $0.name < $1.name }
    }

    public func register(tools: [any Tool]) {
        for tool in tools {
            self.tools[tool.name] = AnyTool(tool)
        }
    }

    /// Registers several tools while preserving the convenient variadic API.
    /// The labeled array call is intentional: calling `register(tool)` here
    /// would select this overload again for an existential tool.
    public func register(_ tools: any Tool...) {
        register(tools: tools)
    }

    public func execute(_ toolCalls: [ToolCall]) async throws(AgentRuntimeError) -> [ToolResult] {
        try await executeWithOutputs(toolCalls).map(\.result)
    }

    public func executeWithOutputs(
        _ toolCalls: [ToolCall]
    ) async throws(AgentRuntimeError) -> [ToolExecution] {
        var executions: [ToolExecution] = []

        for call in toolCalls {
            guard let tool = tool(named: call.name) else {
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: .text("Error: unknown tool: \(call.name)"),
                    failureKind: .rejected
                )
                executions.append(ToolExecution(result: result))
                continue
            }

            let outcome = try await tool.outcome(generatedContent: call.arguments, authority: authority)
            let result = ToolResult(
                toolCallID: call.id,
                name: call.name,
                output: outcome.output,
                failureKind: outcome.failureKind
            )
            executions.append(ToolExecution(result: result))
        }

        return executions
    }
}

/// What one tool call gives the model: the tool's output, or the error it reads
/// when the call failed, so the model can recover instead of the turn ending.
public struct ToolOutcome: Sendable {
    public let output: ToolOutput
    /// Nil when the tool succeeded.
    public let failureKind: ToolFailureKind?
}

extension AnyTool {
    /// Runs the tool, turning its failures into an error the model reads.
    /// Only cancellation escapes.
    public func outcome(
        generatedContent arguments: GeneratedContent,
        authority: any Authority
    ) async throws(AgentRuntimeError) -> ToolOutcome {
        do {
            let output = try await runOutput(generatedContent: arguments, authority: authority)
            return ToolOutcome(output: output, failureKind: nil)
        } catch let denial as EffectDenied {
            return ToolOutcome(output: .text("Error: \(denial)"), failureKind: .rejected)
        } catch let error as ToolError {
            return ToolOutcome(
                output: .text(Self.toolErrorMessage(error, toolName: name)),
                failureKind: Self.failureKind(for: error)
            )
        } catch let error as DecodingError {
            return ToolOutcome(
                output: .text("Error: tool \(name) received invalid arguments: \(Self.decodingMessage(error))"),
                failureKind: .invalidArguments
            )
        } catch is CancellationError {
            throw AgentRuntimeError.cancelled
        } catch {
            return ToolOutcome(output: .text("Error: \(error)"), failureKind: .failed)
        }
    }

    private static func toolErrorMessage(_ error: ToolError, toolName: String) -> String {
        switch error {
        case .unauthorized(let reason):
            return "Error: unauthorized: \(reason)"
        case .missingArgument(let key):
            return "Error: tool \(toolName) missing required argument: \(key)"
        case .invalidArgument(let key, let value):
            return "Error: tool \(toolName) invalid argument \(key): \(value)"
        case .notConfigured(let reason):
            return "Error: tool \(toolName) is not configured: \(reason)"
        }
    }

    private static func failureKind(for error: ToolError) -> ToolFailureKind {
        switch error {
        case .missingArgument, .invalidArgument:
            return .invalidArguments
        case .unauthorized:
            return .rejected
        case .notConfigured:
            return .unavailable
        }
    }

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "at \(codingPath(context.codingPath)): missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            return
                "at \(codingPath(context.codingPath)): expected \(String(describing: type)); \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return
                "at \(codingPath(context.codingPath)): expected \(String(describing: type)); \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "at \(codingPath(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let joined = path.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
    }
}
