import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Cross-restart resume in ``ACPSession``: with a journaled session whose
/// identity matches, the first turn loads the session (`session/load`) and
/// sends only the delta; a resume miss falls back to the full bootstrap.
@Suite("ACPSession resume")
struct ACPSessionResumeTests {
    private enum LoadBehavior: String {
        case succeed
        case fail
    }

    private func makeStub(directory: URL, logPath: String, loadBehavior: LoadBehavior) throws -> URL {
        let loadBranch: String
        switch loadBehavior {
        case .succeed:
            loadBranch =
                #"resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "journaled-session"}}"#
        case .fail:
            loadBranch =
                #"resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Unknown sessionId"}}"#
        }
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
                with open(LOG, "a") as f:
                    f.write("CALL " + str(method) + "\\n")
                if method == "initialize":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}}
                elif method == "session/new":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "fresh-session"}}
                elif method == "session/load":
                    \(loadBranch)
                elif method == "session/prompt":
                    text = msg["params"]["prompt"][0]["text"]
                    with open(LOG, "a") as f:
                        f.write("PROMPT " + text + "\\n<<<END>>>\\n")
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}}
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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-acp-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("journaled session with matching identity resumes and sends only the delta")
    func resumeSuccessSendsDelta() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("calls.log")
        let stub = try makeStub(directory: directory, logPath: logURL.path, loadBehavior: .succeed)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            resumeSession: ModelSessionResume(id: SessionID("journaled-session"), identity: SessionIdentity("id-A"))
        )

        let (stream, response) = try await session.executeTurnPrompt(
            bootstrap: "BOOTSTRAP",
            delta: "DELTA-1",
            memorySnapshot: nil,
            identity: SessionIdentity("id-A")
        )
        for try await _ in stream {}
        _ = try await response.value

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("CALL session/load"))
        #expect(!log.contains("CALL session/new"))
        #expect(log.contains("PROMPT DELTA-1"))
        #expect(!log.contains("BOOTSTRAP"))
    }

    @Test("resume miss falls back to the full bootstrap")
    func resumeMissBootstraps() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("calls.log")
        let stub = try makeStub(directory: directory, logPath: logURL.path, loadBehavior: .fail)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            resumeSession: ModelSessionResume(id: SessionID("journaled-session"), identity: SessionIdentity("id-A"))
        )

        let (stream, response) = try await session.executeTurnPrompt(
            bootstrap: "BOOTSTRAP",
            delta: "DELTA-1",
            memorySnapshot: nil,
            identity: SessionIdentity("id-A")
        )
        for try await _ in stream {}
        _ = try await response.value

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("CALL session/load"))
        #expect(log.contains("CALL session/new"))
        #expect(log.contains("PROMPT BOOTSTRAP"))
    }

    @Test("identity mismatch skips the resume and bootstraps")
    func identityMismatchBootstraps() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("calls.log")
        let stub = try makeStub(directory: directory, logPath: logURL.path, loadBehavior: .succeed)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            resumeSession: ModelSessionResume(id: SessionID("journaled-session"), identity: SessionIdentity("id-OLD"))
        )

        let (stream, response) = try await session.executeTurnPrompt(
            bootstrap: "BOOTSTRAP",
            delta: "DELTA-1",
            memorySnapshot: nil,
            identity: SessionIdentity("id-A")
        )
        for try await _ in stream {}
        _ = try await response.value

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!log.contains("CALL session/load"))
        #expect(log.contains("CALL session/new"))
        #expect(log.contains("PROMPT BOOTSTRAP"))
    }
}
