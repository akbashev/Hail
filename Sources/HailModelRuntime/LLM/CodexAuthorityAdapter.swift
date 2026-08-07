import ACPModel
import HailCore
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Converts native Codex approval requests into Hail effects. Decisions remain
/// values: this adapter neither owns the App Server nor writes to its transport.
struct CodexAuthorityAdapter {
    let workingDirectory: String
    let authority: any Authority

    func sandboxPolicy() async -> CodexSandboxPolicy {
        return CodexSandboxPolicy(
            type: "readOnly",
            networkAccess: false
        )
    }

    func workspaceRoots() async -> [String] {
        let granted = await isGranted(
            FileEffect(path: workingDirectory, action: .read)
        )
        return granted ? [workingDirectory] : []
    }

    func response(
        to message: CodexRPCEnvelope,
        method: String,
        expectedThreadID: String,
        expectedTurnID: String,
        pendingFileChanges: [String: [String]]
    ) async throws -> CodexRPCResponse {
        let id = message.id ?? .number(-1)
        switch method {
        case "item/commandExecution/requestApproval":
            let request = try message.params?.decode(CodexCommandApprovalRequest.self)
            guard request?.threadId == expectedThreadID, request?.turnId == expectedTurnID else {
                return .declined(id: id)
            }
            let granted: Bool
            if let network = request?.networkApprovalContext {
                granted = await isGranted(
                    NetworkEffect(host: network.host, operation: network.protocol ?? "connect")
                )
            } else if let command = request?.command, !command.isEmpty {
                granted = await isGranted(
                    TerminalEffect(command: command, cwd: request?.cwd ?? workingDirectory)
                )
            } else {
                granted = false
            }
            return granted ? .approval(id: id) : .declined(id: id)

        case "item/fileChange/requestApproval":
            let request = try message.params?.decode(CodexFileApprovalRequest.self)
            guard request?.threadId == expectedThreadID, request?.turnId == expectedTurnID else {
                return .declined(id: id)
            }
            var paths = request.flatMap { pendingFileChanges[$0.itemId] } ?? []
            if paths.isEmpty, let root = request?.grantRoot { paths = [absolutePath(root)] }
            var granted = !paths.isEmpty
            for path in paths where granted {
                granted = await isGranted(FileEffect(path: path, action: .write))
            }
            return granted ? .approval(id: id) : .declined(id: id)

        case "item/permissions/requestApproval":
            guard let context = try message.params?.decode(CodexRequestContext.self),
                context.threadId == expectedThreadID, context.turnId == expectedTurnID
            else { return .noPermissions(id: id) }
            return .noPermissions(id: id)

        case "item/tool/requestUserInput":
            guard let context = try message.params?.decode(CodexRequestContext.self),
                context.threadId == expectedThreadID, context.turnId == expectedTurnID
            else { return .success(id: id, result: AnyCodable(["answers": [String: [String]]()])) }
            return .success(id: id, result: AnyCodable(["answers": [String: [String]]()]))

        case "mcpServer/elicitation/request":
            guard let context = try message.params?.decode(CodexRequestContext.self),
                context.threadId == expectedThreadID, context.turnId == expectedTurnID
            else { return .success(id: id, result: AnyCodable(["action": "decline"])) }
            return .success(id: id, result: AnyCodable(["action": "decline"]))

        default:
            return .failure(
                id: id,
                code: -32601,
                message: "Hail does not implement Codex server request '\(method)'."
            )
        }
    }

    func absolutePath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    private func isGranted<Effect: ScopedEffect>(_ effect: Effect) async -> Bool {
        do {
            return try await withEffect(effect, authority: authority) { _ in true }
        } catch {
            return false
        }
    }
}
