import Hail
import ScopedEffect
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Warm/cold routing in ``ClaudeCliEndpoint``: a warm session resumes with
/// only the turn delta (`--resume <id>`), a cold start or identity change
/// sends the full bootstrap transcript. The stub is a Python script that logs
/// its argv and stdin (the prompt) and speaks just enough stream-json.
@Suite("ClaudeCliEndpoint session routing")
struct ClaudeCliSessionRoutingTests {
    private func makeStub(directory: URL, promptLog: String, argsLog: String) throws -> URL {
        let script = """
            #!/usr/bin/env python3
            import sys, json
            prompt = sys.stdin.buffer.read().decode("utf-8", errors="replace")
            with open(\(promptLog.debugDescription), "a") as f:
                f.write(prompt + "\\n<<<END>>>\\n")
            with open(\(argsLog.debugDescription), "a") as f:
                f.write(" ".join(sys.argv[1:]) + "\\n")
            sys.stdout.write(json.dumps({"type": "system", "subtype": "init", "session_id": "stub-claude-session"}) + "\\n")
            sys.stdout.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "OK"}]}}) + "\\n")
            sys.stdout.write(json.dumps({"type": "result", "result": "OK", "is_error": False}) + "\\n")
            sys.stdout.flush()
            """
        let stub = directory.appendingPathComponent("stub-claude.py")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func runTurn(
        endpoint: ClaudeCliEndpoint,
        messages: [LLMMessage],
        delta: [LLMMessage],
        memory: [String] = [],
        identity: String
    ) async -> String? {
        var generated: String?
        for await event in endpoint.stream(
            messages: messages,
            delta: TurnDelta(
                messages: delta,
                workingMemory: memory,
                sessionIdentity: SessionIdentity(identity)
            ),
            authority: FullAuthority(),
            tools: nil,
            responseType: String.self
        ) {
            if case .generated(let value) = event {
                generated = value
            }
        }
        return generated
    }

    @Test("warm session resumes with only the delta; identity change bootstraps")
    func warmResumeColdBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-claude-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptLog = directory.appendingPathComponent("prompts.log")
        let argsLog = directory.appendingPathComponent("args.log")
        let stub = try makeStub(directory: directory, promptLog: promptLog.path, argsLog: argsLog.path)

        let endpoint = try ClaudeCliEndpoint(
            model: "claude-test",
            workingDirectory: directory.path,
            executablePath: stub.path
        )

        let baseMessages = [
            LLMMessage(role: .system, content: "SYSTEM-PROMPT"),
            LLMMessage(role: .user, content: "FIRST"),
        ]

        // Turn 1: cold — full bootstrap, no --resume.
        let first = await runTurn(
            endpoint: endpoint,
            messages: baseMessages,
            delta: [LLMMessage(role: .user, content: "FIRST")],
            identity: "id-A"
        )
        #expect(first == "OK")

        // Turn 2: warm, same identity — resumes the session with only the delta.
        let second = await runTurn(
            endpoint: endpoint,
            messages: baseMessages + [
                LLMMessage(role: .assistant, content: "OK"),
                LLMMessage(role: .user, content: "SECOND"),
            ],
            delta: [LLMMessage(role: .user, content: "SECOND")],
            identity: "id-A"
        )
        #expect(second == "OK")

        // Turn 3: identity changed — fresh bootstrap, no resume.
        let third = await runTurn(
            endpoint: endpoint,
            messages: baseMessages + [
                LLMMessage(role: .assistant, content: "OK"),
                LLMMessage(role: .user, content: "THIRD"),
            ],
            delta: [LLMMessage(role: .user, content: "THIRD")],
            identity: "id-B"
        )
        #expect(third == "OK")

        let prompts = try String(contentsOf: promptLog, encoding: .utf8)
            .components(separatedBy: "<<<END>>>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let args = try String(contentsOf: argsLog, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }

        #expect(prompts.count == 3)
        #expect(args.count == 3)

        #expect(prompts[0].contains("SYSTEM-PROMPT"))
        #expect(!args[0].contains("--resume"))

        #expect(args[1].contains("--resume stub-claude-session"))
        #expect(prompts[1].contains("SECOND"))
        #expect(!prompts[1].contains("SYSTEM-PROMPT"))

        #expect(!args[2].contains("--resume"))
        #expect(prompts[2].contains("SYSTEM-PROMPT"))
    }

    @Test("journaled session primes the first turn with --resume")
    func primedResumeOnFirstTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-claude-primed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptLog = directory.appendingPathComponent("prompts.log")
        let argsLog = directory.appendingPathComponent("args.log")
        let stub = try makeStub(directory: directory, promptLog: promptLog.path, argsLog: argsLog.path)

        let endpoint = try ClaudeCliEndpoint(
            model: "claude-test",
            workingDirectory: directory.path,
            executablePath: stub.path,
            resumeSession: ModelSessionResume(id: SessionID("primed-session"), identity: SessionIdentity("id-A"))
        )

        let result = await runTurn(
            endpoint: endpoint,
            messages: [
                LLMMessage(role: .system, content: "SYSTEM-PROMPT"),
                LLMMessage(role: .user, content: "FIRST"),
            ],
            delta: [LLMMessage(role: .user, content: "FIRST")],
            identity: "id-A"
        )
        #expect(result == "OK")

        let prompts = try String(contentsOf: promptLog, encoding: .utf8)
        let args = try String(contentsOf: argsLog, encoding: .utf8)
        #expect(args.contains("--resume primed-session"))
        #expect(prompts.contains("FIRST"))
        #expect(!prompts.contains("SYSTEM-PROMPT"))
    }

    @Test("resume miss retries cold with the full bootstrap")
    func resumeMissRetriesCold() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-claude-miss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The stub logs argv first, then dies on any --resume call (the CLI
        // session is gone), and answers normally otherwise. Logging before
        // the exit is what makes the resume attempt observable below — an
        // implementation that skipped the resume would log only the cold call.
        let promptLogPath = directory.appendingPathComponent("prompts.log").path
        let argsLogPath = directory.appendingPathComponent("args.log").path
        let script = """
            #!/usr/bin/env python3
            import sys, json
            with open(\(argsLogPath.debugDescription), "a") as f:
                f.write(" ".join(sys.argv[1:]) + "\\n")
            if "--resume" in sys.argv:
                sys.exit(1)
            prompt = sys.stdin.buffer.read().decode("utf-8", errors="replace")
            with open(\(promptLogPath.debugDescription), "a") as f:
                f.write(prompt + "\\n<<<END>>>\\n")
            sys.stdout.write(json.dumps({"type": "system", "subtype": "init", "session_id": "fresh-session"}) + "\\n")
            sys.stdout.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "OK"}]}}) + "\\n")
            sys.stdout.write(json.dumps({"type": "result", "result": "OK", "is_error": False}) + "\\n")
            sys.stdout.flush()
            """
        let stub = directory.appendingPathComponent("stub-claude-miss.py")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let endpoint = try ClaudeCliEndpoint(
            model: "claude-test",
            workingDirectory: directory.path,
            executablePath: stub.path,
            resumeSession: ModelSessionResume(id: SessionID("dead-session"), identity: SessionIdentity("id-A"))
        )

        let result = await runTurn(
            endpoint: endpoint,
            messages: [
                LLMMessage(role: .system, content: "SYSTEM-PROMPT"),
                LLMMessage(role: .user, content: "FIRST"),
            ],
            delta: [LLMMessage(role: .user, content: "FIRST")],
            identity: "id-A"
        )
        #expect(result == "OK")

        let prompts = try String(contentsOf: directory.appendingPathComponent("prompts.log"), encoding: .utf8)
        #expect(prompts.contains("SYSTEM-PROMPT"))

        // The args log must show the --resume attempt followed by the cold
        // bootstrap retry — without the first line the test can't tell a
        // resume-miss-retry from an implementation that never resumed at all.
        let args = try String(contentsOf: directory.appendingPathComponent("args.log"), encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        try #require(args.count == 2)
        #expect(args[0].contains("--resume dead-session"))
        #expect(!args[1].contains("--resume"))
    }

    /// A `claude -p` process that never emits output and never exits must
    /// fail the turn at the stall ceiling instead of blocking it forever.
    /// The stub sleeps only 60s so even a leaked process cleans itself up.
    @Test("hung claude process fails the turn at the stall ceiling")
    func hungProcessFailsAtStallCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-claude-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-claude-hung.sh")
        try "#!/bin/sh\nexec sleep 60\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let endpoint = try ClaudeCliEndpoint(
            model: "claude-test",
            workingDirectory: directory.path,
            executablePath: stub.path,
            maxStallDuration: 2
        )

        let start = Date()
        var failure: ModelEndpointError?
        for await event in endpoint.stream(
            messages: [LLMMessage(role: .user, content: "HELLO")],
            delta: TurnDelta(
                messages: [LLMMessage(role: .user, content: "HELLO")],
                workingMemory: [],
                sessionIdentity: SessionIdentity("stall-ceiling")
            ),
            authority: FullAuthority(),
            tools: nil,
            responseType: String.self
        ) {
            if case .failed(let error) = event { failure = error }
        }

        // The ceiling surfaces as the `withTimeout` error wrapped in
        // `requestFailed` — a concrete identity, not just any failure.
        guard case .requestFailed(let reason) = failure else {
            Issue.record("expected .failed(.requestFailed), got \(String(describing: failure))")
            return
        }
        #expect(reason.contains("TimeoutError"))
        // The lower bound pins the failure to the 2s ceiling: an instant
        // failure would mean the spawn or the stub broke, not the watchdog.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 2)
        #expect(elapsed < 20)
    }
}
