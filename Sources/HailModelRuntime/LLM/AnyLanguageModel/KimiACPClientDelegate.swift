import ACP
import ACPModel
import HailCore
import ScopedEffect
import Synchronization

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Routes ACP client requests from the `kimi-code` CLI into filesystem and
/// terminal operations. Every file read/write and every terminal create is a
/// scoped effect: the request is funneled through a `withEffect` scope
/// checked against the session's authority (e.g. a file policy path-scoped to
/// the working directory — which also pins absolute paths, closing the hole
/// where `/...` used to pass through unchecked). The IO itself still runs in
/// swift-acp's delegates, inside the scope. Permission requests are
/// auto-approved with the safest available allow option (`allow_once`
/// preferred, then `allow_always`, then any allow option) so the local agent
/// can run unattended; reject options or unknown requests are rejected.
/// Hail's `TurnScope` dispatches tool calls that go through the
/// native reasoning loop.
final class KimiACPClientDelegate: ClientDelegate, Sendable {
    private let fileSystem = FileSystemDelegate()
    private let terminal = TerminalDelegate()
    private let workingDirectory: String
    /// The authority fs/terminal requests are checked against. Mutable
    /// because the session applies each turn's lane at prompt start; turns
    /// are serialized per agent, so a new value never races an in-flight
    /// turn's checks.
    private let authorityStorage: Mutex<any Authority>

    private var authority: any Authority {
        authorityStorage.withLock { $0 }
    }

    init(workingDirectory: String, authority: any Authority = FullAuthority()) {
        self.workingDirectory = workingDirectory
        self.authorityStorage = Mutex(authority)
    }

    /// Applies a new turn's lane. Called by the owning ``ACPSession`` at
    /// prompt start; the next prompt simply sets its own.
    func setAuthority(_ authority: any Authority) {
        authorityStorage.withLock { $0 = authority }
    }

    func handleFileReadRequest(
        _ path: String,
        sessionId: String,
        line: Int?,
        limit: Int?
    ) async throws -> ReadTextFileResponse {
        let resolvedPath = resolvePath(path)
        return try await withEffect(FileEffect(path: resolvedPath, action: .read), authority: authority) { _ in
            try await fileSystem.handleFileReadRequest(
                resolvedPath,
                sessionId: sessionId,
                line: line,
                limit: limit
            )
        }
    }

    func handleFileWriteRequest(
        _ path: String,
        content: String,
        sessionId: String
    ) async throws -> WriteTextFileResponse {
        let resolvedPath = resolvePath(path)
        return try await withEffect(FileEffect(path: resolvedPath, action: .write), authority: authority) { _ in
            try await fileSystem.handleFileWriteRequest(
                resolvedPath,
                content: content,
                sessionId: sessionId
            )
        }
    }

    /// Resolves the agent-supplied path to an absolute one. Deliberately not
    /// lexically collapsed: the containment check in the file policy
    /// (`FileEffect.pathPolicy(scopedTo:)`) needs the real, uncollapsed
    /// structure to catch a symlink-then-".." escape (see
    /// `EffectPath.resolveReal`), and the file system delegate below executes
    /// this exact same string, so it resolves identically to how the policy
    /// checked it.
    private func resolvePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(trimmed)
            .path
    }

    func handleTerminalCreate(
        command: String,
        sessionId: String,
        args: [String]?,
        cwd: String?,
        env: [EnvVariable]?,
        outputByteLimit: Int?
    ) async throws -> CreateTerminalResponse {
        let cwd = cwd ?? workingDirectory
        // The effect is evaluated BEFORE swift-acp's `TerminalDelegate`
        // runs — and the delegate wraps operator-bearing command lines in
        // `/bin/sh -c`, the unparseable substrate where a token allowlist
        // means nothing. So the scoped check here is the only decision
        // point, and it is never bypassed by the wrapping: scoped lanes
        // (`TerminalEffect.commandPolicy(allowing:root:)`) deny compounds
        // outright, so nothing that would be wrapped in a shell ever
        // reaches the delegate under those lanes.
        return try await withEffect(
            TerminalEffect(command: command, arguments: args ?? [], cwd: cwd),
            authority: authority
        ) { _ in
            try await terminal.handleTerminalCreate(
                command: command,
                sessionId: sessionId,
                args: args,
                cwd: cwd,
                env: env,
                outputByteLimit: outputByteLimit
            )
        }
    }

    // Output/wait/kill/release manage a terminal that only exists because a
    // scoped `handleTerminalCreate` was granted, so they pass through.

    func handleTerminalOutput(
        terminalId: TerminalId,
        sessionId: String
    ) async throws -> TerminalOutputResponse {
        try await terminal.handleTerminalOutput(
            terminalId: terminalId,
            sessionId: sessionId
        )
    }

    func handleTerminalWaitForExit(
        terminalId: TerminalId,
        sessionId: String
    ) async throws -> WaitForExitResponse {
        try await terminal.handleTerminalWaitForExit(
            terminalId: terminalId,
            sessionId: sessionId
        )
    }

    func handleTerminalKill(
        terminalId: TerminalId,
        sessionId: String
    ) async throws -> KillTerminalResponse {
        try await terminal.handleTerminalKill(
            terminalId: terminalId,
            sessionId: sessionId
        )
    }

    func handleTerminalRelease(
        terminalId: TerminalId,
        sessionId: String
    ) async throws -> ReleaseTerminalResponse {
        try await terminal.handleTerminalRelease(
            terminalId: terminalId,
            sessionId: sessionId
        )
    }

    func handlePermissionRequest(
        request: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        // Auto-select the safest allow option so the local `kimi-code` agent can
        // run unattended. One-time access is preferred over persistent access.
        // Reject options are only chosen when no allow option is available, so
        // the tool call fails cleanly rather than hanging on a cancelled turn.
        let preferredAllows = ["allow_once", "allow_always"]
        for kind in preferredAllows {
            if let option = request.options.first(where: { $0.kind == kind }) {
                return RequestPermissionResponse(outcome: PermissionOutcome(optionId: option.optionId))
            }
        }

        if let anyAllow = request.options.first(where: { $0.kind.contains("allow") }) {
            return RequestPermissionResponse(outcome: PermissionOutcome(optionId: anyAllow.optionId))
        }

        if let rejectOnce = request.options.first(where: { $0.kind == "reject_once" }) {
            return RequestPermissionResponse(outcome: PermissionOutcome(optionId: rejectOnce.optionId))
        }

        return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
    }
}
