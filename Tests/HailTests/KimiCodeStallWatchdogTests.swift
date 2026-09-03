import ACPModel
import ScopedEffect
import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The stall watchdog must fail a prompt whose ACP process stays alive but
/// never answers, instead of hanging the turn forever.
///
/// The stub speaks just enough JSON-RPC to pass `initialize` and
/// `session/new`, then goes completely silent: it never answers
/// `session/prompt` (the turn hangs) nor `session/list` (the watchdog probe).
/// Without the watchdog this test would hang until the 30s initialize
/// timeout; with it, the prompt fails in a few seconds.
/// Whether `error` is the client-process death a watchdog reset
/// (`Client.terminate`) resumes a pending prompt with. swift-acp surfaces
/// that termination either as `processNotRunning` or as `processFailed`
/// (the SIGTERM exit status), depending on internal ordering — both mean
/// "the watchdog killed the process", so tests must accept either.
func isWatchdogTerminationError(_ error: some Error) -> Bool {
    guard let clientError = error as? ClientError else { return false }
    switch clientError {
    case .processNotRunning, .processFailed:
        return true
    default:
        return false
    }
}

@Suite("ACPSession stall watchdog")
struct KimiCodeStallWatchdogTests {
    private let stubScript = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
          [ -z "$id" ] && continue
          case "$line" in
            *'"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\\n' "$id" ;;
            *'"session/new"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"stall-session"}}\\n' "$id" ;;
          esac
        done
        """

    @Test("unresponsive ACP process fails the prompt via watchdog reset")
    func unresponsiveProcessFailsPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-agent.sh")
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path],
            stallTimeout: 2,
            probeTimeout: 2
        )

        let start = Date()
        // The watchdog fails the pending prompt by terminating the client,
        // which resumes its request with a watchdog termination error — a
        // prompt that failed instantly for any other reason must not pass.
        await #expect {
            _ = try await session.sendPrompt("hello")
        } throws: { isWatchdogTerminationError($0) }
        // ~2s stall detection + ~2s probe timeout + slack; far below the 30s
        // initialize timeout that a hung turn would hit without a watchdog.
        #expect(Date().timeIntervalSince(start) < 20)
    }

    /// A process that stays alive — it keeps answering the `session/list`
    /// probe — but never answers `session/prompt` must still fail once the
    /// stall ceiling is reached. Without the ceiling the probe would extend
    /// the turn indefinitely (a healthy event loop is not turn progress).
    private let aliveButWedgedScript = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
          [ -z "$id" ] && continue
          case "$line" in
            *'"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\\n' "$id" ;;
            *'"session/new"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"wedged-session"}}\\n' "$id" ;;
            *'"session/list"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessions":[]}}\\n' "$id" ;;
          esac
        done
        """

    @Test("alive but non-progressing turn fails at the stall ceiling")
    func aliveButWedgedTurnFailsAtCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-wedged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-agent.sh")
        try aliveButWedgedScript.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path],
            stallTimeout: 1,
            probeTimeout: 1,
            maxStallDuration: 3
        )

        let start = Date()
        // Same watchdog error as above: the ceiling path also resets the
        // session, which fails the pending prompt via Client.terminate.
        await #expect {
            _ = try await session.sendPrompt("hello")
        } throws: { isWatchdogTerminationError($0) }
        // The process answers every probe, so only the `maxStallDuration`
        // ceiling can end the turn — proving the ceiling, not probe failure,
        // is what fails a live-but-wedged session. The lower bound pins the
        // failure to the ceiling: an instant failure would mean the turn died
        // for an unrelated reason, not because 3s passed without progress.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 3)
        #expect(elapsed < 20)
    }
}

/// A laned turn applies its authority to the warm ACP session at prompt
/// start (`ACPSession.executeTurnPrompt` → `setAuthority`): the delegate's
/// model-facing effect checks must follow the lane, not the broader
/// creation authority the session was built with.
@Suite("KimiACPClientDelegate lane authority")
struct KimiACPClientDelegateLaneTests {
    @Test("untrusted-input lane denies a file read the creation authority allowed")
    func laneSwitchDeniesFileRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-delegate-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let delegate = KimiACPClientDelegate(workingDirectory: directory.path, authority: FullAuthority())
        _ = try await delegate.handleFileReadRequest(file.path, sessionId: "s", line: nil, limit: nil)

        delegate.setAuthority(CompositeAuthority.untrustedInput)
        await #expect {
            _ = try await delegate.handleFileReadRequest(file.path, sessionId: "s", line: nil, limit: nil)
        } throws: { error in
            error is EffectDenied
        }
    }
}
