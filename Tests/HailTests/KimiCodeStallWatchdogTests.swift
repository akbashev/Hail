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

        let session = ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path],
            stallTimeout: 2,
            probeTimeout: 2
        )

        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await session.sendPrompt("hello")
        }
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

        let session = ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path],
            stallTimeout: 1,
            probeTimeout: 1,
            maxStallDuration: 3
        )

        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await session.sendPrompt("hello")
        }
        // The process answers every probe, so only the `maxStallDuration`
        // ceiling can end the turn — proving the ceiling, not probe failure,
        // is what fails a live-but-wedged session.
        #expect(Date().timeIntervalSince(start) < 20)
    }
}
