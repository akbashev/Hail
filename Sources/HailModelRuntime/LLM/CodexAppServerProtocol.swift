import ACPModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum CodexSessionError: Error, CustomStringConvertible {
    case disconnected
    case requestFailed(String)
    case missingThreadID
    case turnFailed(String)

    var description: String {
        switch self {
        case .disconnected: return "Codex App Server disconnected."
        case .requestFailed(let message): return message
        case .missingThreadID: return "Codex App Server returned no thread id."
        case .turnFailed(let message): return message
        }
    }
}

extension AnyCodable {
    var integer: Int? {
        value as? Int
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    static func decode(from data: Data) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: data)
    }
}

extension RequestId {
    var integer: Int? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

struct CodexRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let id: Int
    let method: String
    let params: Params
}

struct CodexRPCNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    let method: String
    let params: Params?

    init(method: String, params: Params? = nil) {
        self.method = method
        self.params = params
    }
}

struct CodexRPCResponse: Encodable, Sendable {
    struct Failure: Encodable, Sendable {
        let code: Int
        let message: String
    }

    let id: RequestId
    let result: AnyCodable?
    let error: Failure?

    static func success(id: RequestId, result: AnyCodable) -> Self {
        Self(id: id, result: result, error: nil)
    }

    static func approval(id: RequestId) -> Self {
        success(id: id, result: AnyCodable(["decision": "accept"]))
    }

    static func declined(id: RequestId) -> Self {
        success(id: id, result: AnyCodable(["decision": "decline"]))
    }

    static func noPermissions(id: RequestId) -> Self {
        let fileSystem: [String: any Sendable] = [
            "read": [String](),
            "write": [String](),
        ]
        let network: [String: any Sendable] = ["enabled": false]
        let permissions: [String: any Sendable] = [
            "fileSystem": fileSystem,
            "network": network,
        ]
        let result: [String: any Sendable] = [
            "permissions": permissions,
            "scope": "turn",
        ]
        return success(
            id: id,
            result: AnyCodable(result)
        )
    }

    static func failure(id: RequestId, code: Int, message: String) -> Self {
        Self(id: id, result: nil, error: Failure(code: code, message: message))
    }
}

struct CodexRPCEnvelope: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let code: Int?
        let message: String
    }

    let id: RequestId?
    let method: String?
    let params: AnyCodable?
    let result: AnyCodable?
    let error: Failure?
}

enum CodexAppServerWire {
    static func decode(_ line: Data) throws -> CodexRPCEnvelope {
        try JSONDecoder().decode(CodexRPCEnvelope.self, from: line)
    }

    static func encode<Message: Encodable & Sendable>(_ message: Message) throws -> Data {
        try JSONEncoder().encode(message)
    }
}

struct CodexInitializeParams: Codable, Sendable {
    struct Capabilities: Codable, Sendable {
        let experimentalApi: Bool
    }

    struct ClientInfo: Codable, Sendable {
        let name: String
        let title: String
        let version: String
    }

    let clientInfo: ClientInfo
    let capabilities: Capabilities
}

struct CodexThreadParams: Codable, Sendable {
    let model: String
    let cwd: String
    let approvalPolicy: String
    let sandbox: String
    let serviceName: String
    let config: CodexThreadConfig?
    var threadId: String?
}

struct CodexThreadConfig: Codable, Sendable {
    struct MCPServer: Codable, Sendable {
        let command: String
        let args: [String]
        let envVars: [String]
        let enabled: Bool
        let required: Bool
        let defaultToolsApprovalMode: String

        enum CodingKeys: String, CodingKey {
            case command, args, enabled, required
            case envVars = "env_vars"
            case defaultToolsApprovalMode = "default_tools_approval_mode"
        }
    }

    let mcpServers: [String: MCPServer]

    enum CodingKeys: String, CodingKey {
        case mcpServers = "mcp_servers"
    }
}

struct CodexThreadResponse: Codable, Sendable {
    struct Thread: Codable, Sendable {
        let id: String
        /// The live session-tree root. This is distinct from `id` for forked
        /// threads; App Server clients must preserve the server-provided value.
        let sessionId: String?
    }

    let thread: Thread
}

struct CodexTurnResponse: Codable, Sendable {
    struct Turn: Codable, Sendable {
        let id: String
    }

    let turn: Turn
}

struct CodexTurnStartParams: Codable, Sendable {
    struct Input: Codable, Sendable {
        let type: String
        let text: String
    }

    let threadId: String
    let input: [Input]
    let cwd: String
    let approvalPolicy: String
    let sandboxPolicy: CodexSandboxPolicy
    let runtimeWorkspaceRoots: [String]
    let outputSchema: AnyCodable?
}

struct CodexSandboxPolicy: Codable, Sendable {
    let type: String
    let networkAccess: Bool
}

struct CodexTextDelta: Codable, Sendable {
    let delta: String
}

struct CodexItemNotification: Codable, Sendable {
    struct Item: Codable, Sendable {
        struct Change: Codable, Sendable {
            let path: String
        }

        let id: String?
        let type: String
        let text: String?
        let server: String?
        let tool: String?
        let command: String?
        let cwd: String?
        let changes: [Change]?
    }

    let item: Item
}

struct CodexTurnCompleted: Codable, Sendable {
    struct Turn: Codable, Sendable {
        struct Failure: Codable, Sendable {
            let message: String
        }

        let status: String
        let error: Failure?
    }

    let turn: Turn
}

struct CodexErrorNotification: Codable, Sendable {
    let message: String
}

struct CodexRequestContext: Codable, Sendable {
    let threadId: String
    let turnId: String?
}

struct CodexCommandApprovalRequest: Codable, Sendable {
    struct NetworkContext: Codable, Sendable {
        let host: String
        let `protocol`: String?
    }

    let threadId: String
    let turnId: String
    let command: String?
    let cwd: String?
    let networkApprovalContext: NetworkContext?
}

struct CodexFileApprovalRequest: Codable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
    let grantRoot: String?
}
