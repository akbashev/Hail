import ScopedEffect

public struct ToolExecution: Sendable {
    public let result: ToolResult
    public let output: ToolOutput

    public init(result: ToolResult, output: ToolOutput) {
        self.result = result
        self.output = output
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
        Array(tools.values)
    }

    public func schemas(forTools toolNames: [String]? = nil) -> [LLMToolSchema] {
        if let toolNames {
            let allowed = Set(toolNames)
            return tools.values
                .filter { allowed.contains($0.name) }
                .map { $0.schema }
        }
        return tools.values.map { $0.schema }
    }

    public func execute(_ toolCalls: [LLMToolCall]) async throws(AgentRuntimeError) -> [ToolResult] {
        try await execute(
            toolCalls.map {
                ToolCall(
                    id: $0.id,
                    name: $0.function.name,
                    arguments: ToolArguments(json: $0.function.arguments)
                )
            })
    }

    public func register(tools: [any Tool]) {
        for tool in tools {
            register(tool)
        }
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
                    output: "Error: unknown tool: \(call.name)",
                    isError: true
                )
                executions.append(ToolExecution(result: result, output: .text(result.output)))
                continue
            }

            do {
                let output = try await tool.executeOutput(input: call.arguments, authority: authority)
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: output.transcript,
                    isError: false
                )
                executions.append(ToolExecution(result: result, output: output))
            } catch let denial as EffectDenied {
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: "Error: \(denial)",
                    isError: true
                )
                executions.append(ToolExecution(result: result, output: .text(result.output)))
            } catch let error as ToolError {
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: Self.toolErrorMessage(error, toolName: call.name),
                    isError: true
                )
                executions.append(ToolExecution(result: result, output: .text(result.output)))
            } catch let error as DecodingError {
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: "Error: tool \(call.name) received invalid arguments: \(Self.decodingMessage(error))",
                    isError: true
                )
                executions.append(ToolExecution(result: result, output: .text(result.output)))
            } catch is CancellationError {
                throw AgentRuntimeError.cancelled
            } catch {
                let result = ToolResult(
                    toolCallID: call.id,
                    name: call.name,
                    output: "Error: \(error)",
                    isError: true
                )
                executions.append(ToolExecution(result: result, output: .text(result.output)))
            }
        }

        return executions
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

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(codingPath(context.codingPath))"
        case .typeMismatch(_, let context):
            return context.debugDescription
        case .valueNotFound(_, let context):
            return context.debugDescription
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let joined = path.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
    }
}
