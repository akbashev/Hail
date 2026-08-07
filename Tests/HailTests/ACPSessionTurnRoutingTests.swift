import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Warm/cold routing in ``ACPSession/executeTurnPrompt``: a live session with
/// a matching identity receives only the turn delta; a cold start or an
/// identity change bootstraps with the full transcript; memory re-sends only
/// when it changes. The stub is a Python JSON-RPC process that logs every
/// `session/prompt` text to a file.
@Suite("ACPSession turn routing")
struct ACPSessionTurnRoutingTests {
    private func makeStub(directory: URL, logPath: String) throws -> URL {
        let script = """
            #!/usr/bin/env python3
            import sys, json
            LOG = \(logPath.debugDescription)
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                mid = msg.get("id")
                method = msg.get("method")
                if mid is None:
                    continue
                if method == "initialize":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {}}}
                elif method == "session/new":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "stub-session"}}
                elif method == "session/prompt":
                    text = msg["params"]["prompt"][0]["text"]
                    with open(LOG, "a") as f:
                        f.write(text + "\\n<<<END>>>\\n")
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}}
                elif method == "session/list":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessions": []}}
                else:
                    resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}}
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            """
        let stub = directory.appendingPathComponent("stub-agent.py")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func runTurn(
        session: ACPSession,
        bootstrap: String,
        delta: String,
        memory: String?,
        identity: String
    ) async throws {
        let (stream, response) = try await session.executeTurnPrompt(
            bootstrap: bootstrap,
            delta: delta,
            memorySnapshot: memory,
            identity: SessionIdentity(identity)
        )
        for try await _ in stream {}
        _ = try await response.value
    }

    @Test("warm session receives only the delta; identity change bootstraps")
    func warmDeltaColdBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-turn-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("prompts.log")
        let stub = try makeStub(directory: directory, logPath: logURL.path)

        let session = ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path]
        )

        // Turn 1: no session yet — cold bootstrap with the full transcript.
        try await runTurn(
            session: session, bootstrap: "BOOTSTRAP-1 turn-clock-cold", delta: "DELTA-1 turn-clock-cold",
            memory: "MEM-A", identity: "id-A")

        // Turn 2: warm, same identity and memory — only the delta is sent.
        try await runTurn(
            session: session, bootstrap: "BOOTSTRAP-2 turn-clock-warm", delta: "DELTA-2 turn-clock-warm",
            memory: "MEM-A", identity: "id-A")

        // Turn 3: warm, changed memory — memory snapshot rides the delta.
        try await runTurn(
            session: session, bootstrap: "BOOTSTRAP-3", delta: "DELTA-3", memory: "MEM-B", identity: "id-A")

        // Turn 4: identity changed (config edit) — full bootstrap again.
        try await runTurn(
            session: session, bootstrap: "BOOTSTRAP-4", delta: "DELTA-4", memory: "MEM-B", identity: "id-B")

        let log = try String(contentsOf: logURL, encoding: .utf8)
        let entries = log.components(separatedBy: "<<<END>>>").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        #expect(entries.count == 4)
        #expect(entries[0].contains("BOOTSTRAP-1"))
        #expect(entries[0].contains("turn-clock-cold"))
        #expect(entries[1].contains("DELTA-2"))
        #expect(entries[1].contains("turn-clock-warm"))
        #expect(!entries[1].contains("BOOTSTRAP-2"))
        #expect(!entries[1].contains("MEM-A"))
        #expect(entries[2].contains("MEM-B"))
        #expect(entries[2].contains("DELTA-3"))
        #expect(entries[3].contains("BOOTSTRAP-4"))
        #expect(!entries[3].contains("DELTA-4"))
    }
}
