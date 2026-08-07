import ScopedEffect

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
        var results: [ToolResult] = []

        for call in toolCalls {
            guard let tool = tool(named: call.name) else {
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: "Error: unknown tool: \(call.name)",
                        isError: true
                    ))
                continue
            }

            do {
                let output: String
                output = try await tool.execute(input: call.arguments, authority: authority)
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: output,
                        isError: false
                    ))
            } catch let denial as EffectDenied {
                // Denial is model-visible: the refusal is ordinary feedback.
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: "Error: \(denial)",
                        isError: true
                    ))
            } catch let error as ToolError {
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: Self.toolErrorMessage(error, toolName: call.name),
                        isError: true
                    ))
            } catch let error as DecodingError {
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: "Error: tool \(call.name) received invalid arguments: \(Self.decodingMessage(error))",
                        isError: true
                    ))
            } catch {
                results.append(
                    ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: "Error: \(error)",
                        isError: true
                    ))
            }
        }

        return results
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
