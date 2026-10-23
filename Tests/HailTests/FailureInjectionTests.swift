import ACPModel
import AnyLanguageModel
import Foundation
import Hail
import ScopedEffect
import Testing

@testable import HailModelRuntime

#if canImport(Darwin)
    import Darwin
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#endif

/// Failure-injection coverage for Hail-owned failure modes: harness process
/// death mid-turn, protocol-violating harnesses, repeated crash recovery at
/// the `AgentState` fold, and the journal decode boundary. These pin the
/// property behind the downstream "journal replays on restart, resumes
/// exactly where it left off" guarantee against uncooperative harnesses, not
/// just well-behaved stubs.
///
/// Cluster-level failures (downed EventStore singleton, agent-process kill
/// with virtual-actor reactivation, multi-node failover) are deliberately out
/// of scope here: they need a real cluster and are covered by stagehand
/// integration tests.

/// Polls a condition (a stub's signal file appearing) instead of sleeping a
/// fixed duration, so the tests stay fast and deterministic.
private enum WaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case .timedOut(let what): return "Timed out waiting for \(what)"
        }
    }
}

private func waitForCondition(
    _ description: String,
    timeout: TimeInterval = 10,
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WaitError.timedOut(description) }
        try await Task.sleep(for: .milliseconds(25))
    }
}

private func makeTempDirectory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Harness SIGKILL mid-turn (ACP)

/// The stub ACP harness is SIGKILLed while a prompt is in flight. The turn
/// must fail cleanly — concrete process-death error, session reset, no hang —
/// and the next turn must cold-start a fresh harness process and succeed.
@Suite("ACP harness SIGKILL mid-turn")
struct ACPHarnessKillTests {
    /// Writes its pid at startup. The first `session/prompt` of the first
    /// process signals readiness and is never answered (the test kills the
    /// process there); prompts after the restart answer `end_turn` normally.
    private func makeStub(directory: URL) throws -> (stub: URL, pid: URL, ready: URL) {
        let pidURL = directory.appendingPathComponent("stub.pid")
        let readyURL = directory.appendingPathComponent("prompt-ready")
        let stateURL = directory.appendingPathComponent("prompt-count")
        let script = """
            #!/usr/bin/env python3
            import sys, json, os
            PID = \(pidURL.path.debugDescription)
            READY = \(readyURL.path.debugDescription)
            STATE = \(stateURL.path.debugDescription)
            with open(PID, "w") as f:
                f.write(str(os.getpid()))
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
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "kill-session"}}
                elif method == "session/list":
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessions": []}}
                elif method == "session/prompt":
                    count = 0
                    if os.path.exists(STATE):
                        with open(STATE) as f:
                            count = int(f.read().strip() or "0")
                    count += 1
                    with open(STATE, "w") as f:
                        f.write(str(count))
                    if count == 1:
                        # First prompt of the first process: signal that the
                        # turn is parked, then never answer — the test
                        # SIGKILLs this process while the turn is in flight.
                        with open(READY, "w") as f:
                            f.write("ready")
                        continue
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}}
                else:
                    resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}}
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            """
        let stub = directory.appendingPathComponent("stub-agent.py")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return (stub, pidURL, readyURL)
    }

    @Test("SIGKILL mid-prompt fails the turn; a fresh session recovers")
    func sigkillMidTurnFailsAndRecovers() async throws {
        let directory = try makeTempDirectory("hail-acp-kill")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stub, pidURL, readyURL) = try makeStub(directory: directory)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            // The SIGKILL is the failure mechanism under test: pin the
            // watchdog durations long so it cannot fire first and mask the
            // crash path.
            stallTimeout: 60,
            probeTimeout: 60,
            maxStallDuration: 3_600
        )

        let start = Date()
        let promptTask = Task { try await session.sendPrompt("hello") }

        // Wait for the harness to be up and the prompt to be parked in
        // flight, then kill the process out from under the turn.
        try await waitForCondition("stub pid file") {
            FileManager.default.fileExists(atPath: pidURL.path)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        try await waitForCondition("prompt in flight") {
            FileManager.default.fileExists(atPath: readyURL.path)
        }
        kill(pid, SIGKILL)

        // The turn must fail with the process-death error, not hang.
        await #expect {
            _ = try await promptTask.value
        } throws: { error in
            guard let clientError = error as? ClientError, case .processFailed = clientError else {
                return false
            }
            return true
        }
        #expect(Date().timeIntervalSince(start) < 20)

        // The failed turn reset the session: no stale session id survives.
        #expect(await session.currentSessionID == nil)

        // Recovery: the next turn cold-starts a fresh harness process whose
        // stub answers normally.
        let result = try await session.sendPrompt("are you there")
        #expect(result.stopReason == .endTurn)
        #expect(await session.currentSessionID == SessionID("kill-session"))
        let recoveredPID = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(recoveredPID != pidText)
    }
}

// MARK: - Harness SIGKILL mid-turn (Codex)

/// Same crash, against the Codex app-server session: its
/// `StdioTransport.handleTermination` must finish the parked turn's event
/// stream so the turn surfaces `.disconnected` instead of hanging, and the
/// durable thread id must survive so the next turn resumes it on a fresh
/// process.
@Suite("Codex harness SIGKILL mid-turn")
struct CodexHarnessKillTests {
    /// The first `turn/start` of the first process signals readiness and is
    /// never completed (the test kills the process there); after the restart
    /// the stub answers `thread/resume` and completes the turn with
    /// "RECOVERED".
    private func makeStub(directory: URL) throws -> (stub: URL, pid: URL, ready: URL, requests: URL) {
        let pidURL = directory.appendingPathComponent("stub.pid")
        let readyURL = directory.appendingPathComponent("turn-ready")
        let stateURL = directory.appendingPathComponent("turn-count")
        let requestsURL = directory.appendingPathComponent("requests.log")
        let script = """
            #!/usr/bin/env python3
            import sys, json, os
            PID = \(pidURL.path.debugDescription)
            READY = \(readyURL.path.debugDescription)
            STATE = \(stateURL.path.debugDescription)
            REQUESTS = \(requestsURL.path.debugDescription)
            with open(PID, "w") as f:
                f.write(str(os.getpid()))
            def send(value):
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    send({"id": message["id"], "result": {}})
                elif method in ("thread/start", "thread/resume"):
                    with open(REQUESTS, "a") as f:
                        f.write(method + "\\n")
                    send({"id": message["id"], "result": {"thread": {"id": "kill-thread", "sessionId": "kill-session"}}})
                elif method == "turn/start":
                    count = 0
                    if os.path.exists(STATE):
                        with open(STATE) as f:
                            count = int(f.read().strip() or "0")
                    count += 1
                    with open(STATE, "w") as f:
                        f.write(str(count))
                    send({"id": message["id"], "result": {"turn": {"id": "turn-%d" % count, "status": "inProgress"}}})
                    if count == 1:
                        # First turn of the first process: signal that the
                        # turn is parked, then never complete it — the test
                        # SIGKILLs this process while the turn is in flight.
                        with open(READY, "w") as f:
                            f.write("ready")
                    else:
                        send({"method": "item/agentMessage/delta", "params": {"delta": "RECOVERED"}})
                        send({"method": "item/completed", "params": {"item": {"id": "message-1", "type": "agentMessage", "text": "RECOVERED"}}})
                        send({"method": "turn/completed", "params": {"turn": {"status": "completed"}}})
            """
        let stub = directory.appendingPathComponent("stub-codex.py")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return (stub, pidURL, readyURL, requestsURL)
    }

    @Test("SIGKILL mid-turn surfaces disconnected; the next turn resumes the thread")
    func sigkillMidTurnDisconnectsAndResumes() async throws {
        let directory = try makeTempDirectory("hail-codex-kill")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stub, pidURL, readyURL, requestsURL) = try makeStub(directory: directory)

        let session = try CodexAppServerSession(
            model: "gpt-test",
            workingDirectory: directory.path,
            agentID: nil,
            contextLabel: nil,
            mcpServerConfiguration: nil,
            executionPolicy: .autonomousWorkspace,
            executablePath: stub.path,
            resumeSession: nil,
            authority: FullAuthority(),
            // The SIGKILL is the failure mechanism under test: pin the stall
            // ceiling long so it cannot fire first and mask the crash path.
            maxStallDuration: 3_600
        )

        func turn(_ full: String, _ delta: String) async throws -> String {
            try await session.runTurn(
                fullPrompt: full,
                deltaPrompt: delta,
                identity: SessionIdentity("id-A"),
                outputSchema: nil,
                turnAuthority: nil,
                onNarration: { _ in }
            )
        }

        let start = Date()
        let turnTask = Task { try await turn("hello", "hello") }

        try await waitForCondition("stub pid file") {
            FileManager.default.fileExists(atPath: pidURL.path)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        try await waitForCondition("turn in flight") {
            FileManager.default.fileExists(atPath: readyURL.path)
        }
        kill(pid, SIGKILL)

        // Process death surfaces as transport EOF: the turn's event stream
        // ends mid-turn and `runTurn` classifies it as a lost connection.
        await #expect {
            _ = try await turnTask.value
        } throws: { error in
            guard let sessionError = error as? CodexSessionError, case .disconnected = sessionError else {
                return false
            }
            return true
        }
        #expect(Date().timeIntervalSince(start) < 20)

        // The durable thread id survives the crash so the next turn can
        // resume it on the fresh process instead of re-bootstrapping.
        #expect(await session.currentSessionID == SessionID("kill-thread"))

        let recovered = try await turn("hello", "delta-after-crash")
        #expect(recovered == "RECOVERED")

        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
        #expect(requests.contains("thread/resume"))
        await session.terminate()
    }
}

// MARK: - Protocol-violating harness (ACP)

/// A harness that speaks broken JSON-RPC. Hail must contain the violation:
/// the turn fails cleanly with a concrete error (never hangs, never crashes)
/// when the violation breaks the turn, and well-formed traffic that follows
/// garbage keeps working.
@Suite("Protocol-violating ACP harness")
struct ProtocolViolatingHarnessTests {
    /// Answers `initialize`/`session/new`; the first `session/prompt` gets a
    /// complete-but-undecodable JSON line and is never answered. The
    /// `session/list` probe gets a method-not-found error, so the stall
    /// watchdog resets the session and fails the parked turn. Prompts after
    /// the restart answer `end_turn` normally.
    private func makeMalformedStub(directory: URL) throws -> URL {
        let stateURL = directory.appendingPathComponent("prompt-count")
        let script = """
            #!/usr/bin/env python3
            import sys, json, os
            STATE = \(stateURL.path.debugDescription)
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
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "violating-session"}}
                elif method == "session/prompt":
                    count = 0
                    if os.path.exists(STATE):
                        with open(STATE) as f:
                            count = int(f.read().strip() or "0")
                    count += 1
                    with open(STATE, "w") as f:
                        f.write(str(count))
                    if count == 1:
                        # Malformed JSON-RPC mid-session: balanced JSON that
                        # matches no ACP message shape, then silence. The
                        # client drops it at the decode boundary; the watchdog
                        # fails the parked turn.
                        sys.stdout.write('{"this is":"not a valid ACP message"}\\n')
                        sys.stdout.flush()
                        continue
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

    @Test("malformed JSON-RPC mid-session fails the turn via watchdog; a fresh session recovers")
    func malformedMidSessionFailsAndRecovers() async throws {
        let directory = try makeTempDirectory("hail-acp-malformed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try makeMalformedStub(directory: directory)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            stallTimeout: 1,
            probeTimeout: 1,
            maxStallDuration: 3_600
        )

        let start = Date()
        // The malformed response is dropped at swift-acp's decode boundary,
        // so the prompt stays parked until the watchdog's probe also fails
        // and the session reset resumes it with a watchdog termination error.
        await #expect {
            _ = try await session.sendPrompt("hello")
        } throws: { isWatchdogTerminationError($0) }
        // The lower bound pins the failure to the watchdog (stall detection +
        // probe timeout): an instant failure would mean the turn died for an
        // unrelated reason.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 2)
        #expect(elapsed < 20)
        #expect(await session.currentSessionID == nil)

        // Recovery: the reset cleared the poisoned session; the next turn
        // cold-starts a fresh process whose stub answers normally.
        let result = try await session.sendPrompt("are you there")
        #expect(result.stopReason == .endTurn)
        #expect(await session.currentSessionID == SessionID("violating-session"))
    }

    /// Emits garbage before any request arrives: a plain non-JSON line, an
    /// unsolicited `session/update` for a ghost session, a response for a
    /// request id that never existed, and an unknown notification. swift-acp
    /// drops all four at its decode/routing boundary, so the correct behavior
    /// is containment — the turn proceeds normally (no hang, no crash).
    private func makeGarbageStub(directory: URL) throws -> URL {
        let script = """
            #!/usr/bin/env python3
            import sys, json
            # Garbage before any request: none of this may break the session.
            sys.stdout.write("this is not json at all\\n")
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "ghost", "update": {"sessionUpdate": "no_such_update"}}}) + "\\n")
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": 9999, "result": {"phantom": True}}) + "\\n")
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "totally/bogus", "params": {}}) + "\\n")
            sys.stdout.flush()
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
                    resp = {"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "garbage-session"}}
                elif method == "session/prompt":
                    # A legitimate streamed chunk proves notification routing
                    # still works after the startup garbage.
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "garbage-session", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "CHUNK"}}}}) + "\\n")
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

    @Test("unsolicited garbage before any request is contained; turns proceed normally")
    func startupGarbageIsContained() async throws {
        let directory = try makeTempDirectory("hail-acp-garbage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try makeGarbageStub(directory: directory)

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/usr/bin/python3",
            agentArguments: [stub.path],
            stallTimeout: 60,
            probeTimeout: 60,
            maxStallDuration: 3_600
        )

        let first = try await session.sendPrompt("hello")
        #expect(first.stopReason == .endTurn)
        #expect(first.text == "CHUNK")

        // A second (warm) turn proves the startup garbage poisoned neither
        // the session nor the single notification consumer.
        let second = try await session.sendPrompt("again")
        #expect(second.stopReason == .endTurn)
        #expect(second.text == "CHUNK")
    }
}

// MARK: - Repeated crash (AgentState fold)

/// A crashed turn stays open and the agent finishes it: what the resumed run does lands in the
/// same turn, however often it crashes, and its input is never journaled again.
@Suite("AgentState repeated crash")
struct RepeatedCrashTests {
    @Test("a turn resumed after two crashes is still one turn with all its work")
    func repeatedCrashKeepsOneTurn() throws {
        let call = { (id: String) in ToolCall(id: id, name: "read_file", arguments: GeneratedContent(properties: [:])) }
        let result = { (id: String) in ToolResult(toolCallID: id, name: "read_file", output: .text("ok")) }
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))
        let input = AgentHistory.Input(
            content: GeneratedContent("hello"), at: Date(timeIntervalSince1970: 2_000))

        try state.apply(.history(.received(input, turn: TurnID("t1"))))
        for (round, id) in ["call-1", "call-2"].enumerated() {
            let at = Date(timeIntervalSince1970: 2_001 + TimeInterval(round))
            try state.apply(.history(.called(call(id), at: at)))
            try state.apply(.history(.resulted(result(id), at: at)))
            state.normalizeAfterReplay()
            #expect(state.history.open?.id == TurnID("t1"))
        }
        try state.apply(
            .history(.replied(.init(content: GeneratedContent("done"), at: Date(timeIntervalSince1970: 4_100)))))

        #expect(state.history.closed.count == 1)
        #expect(state.history.closed[0].steps.count == 4)
        #expect(state.history.open == nil)
    }
}

// MARK: - Corrupted journal tail (decode boundary)

/// The journal decode boundary Hail owns: replay folds events one at a time,
/// so a corrupted tail event fails loudly at `JSONDecoder` and never
/// partially applies — replay through the last valid event recovers the
/// exact pre-crash state. Torn-line *framing* (skipping or repairing a
/// partial final JSONL line) is the EventStore's job, and the store is
/// bring-your-own (stagehand's `FileEventStore` lives outside this package);
/// what Hail owns — the `AgentEvent` decode + `AgentState` fold — is pinned
/// here as loud. In the session-resume path a malformed entry therefore
/// throws during replay, before any `ModelSessionResume` can be constructed
/// from partial state.
@Suite("Corrupted journal tail")
struct CorruptedJournalTests {
    private func encode(_ event: AgentEvent) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    private func makeToolResult(id: String, output: String) throws -> ToolResult {
        ToolResult(toolCallID: id, name: "read_file", output: .text(output))
    }

    @Test("a torn tail event throws and never partially applies")
    func tornTailThrowsAndKeepsState() throws {
        let input = AgentHistory.Input(
            content: GeneratedContent("hello"), at: Date(timeIntervalSince1970: 2_000))
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        let validLines = [
            try encode(.history(.received(input, turn: TurnID("t1")))),
            try encode(
                .history(
                    .called(
                        ToolCall(id: "call-1", name: "read_file", arguments: GeneratedContent(properties: [:])),
                        at: Date(timeIntervalSince1970: 2_001)))),
        ]
        for line in validLines {
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
            try state.apply(event)
        }
        let beforeTail = state.history
        #expect(beforeTail.open?.steps.count == 1)

        // A crash mid-write leaves a torn final line: a valid prefix of a
        // real event, cut before the JSON closes.
        let tailEvent = try encode(
            .history(.resulted(try makeToolResult(id: "call-1", output: "ok"), at: Date(timeIntervalSince1970: 2_002)))
        )
        let torn = String(tailEvent.prefix(tailEvent.count / 2))
        #expect {
            _ = try JSONDecoder().decode(AgentEvent.self, from: Data(torn.utf8))
        } throws: { error in
            error is DecodingError
        }

        // Syntactically valid JSON that names no known event is just as loud.
        #expect {
            _ = try JSONDecoder().decode(AgentEvent.self, from: Data(#"{"bogusEvent":{"_0":1}}"#.utf8))
        } throws: { error in
            error is DecodingError
        }

        // The failed decodes never touched the state: replay through the
        // last valid event recovers the exact pre-crash state, with the
        // interrupted turn still open for the agent to finish.
        state.normalizeAfterReplay()
        #expect(state.history == beforeTail)
    }

    @Test("resume identity survives a corrupted tail decode failure")
    func resumeIdentitySurvivesCorruptTail() throws {
        var state = AgentState(agentID: AgentID(role: Role("coder"), contextID: AgentContextID("T-1")))

        let validLines = [
            try encode(.modelSessionIdentified(id: SessionID("session-1"), identity: SessionIdentity("fp-A"))),
            try encode(
                .history(
                    .received(
                        .init(
                            content: GeneratedContent("hi"),
                            at: Date(timeIntervalSince1970: 1_999)),
                        turn: TurnID("t1")))),
        ]
        for line in validLines {
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
            try state.apply(event)
        }
        #expect(state.modelSession?.id == SessionID("session-1"))

        // A torn `modelSessionIdentified` line fails loudly instead of
        // folding a partial session id into the resume path.
        #expect {
            _ = try JSONDecoder().decode(
                AgentEvent.self,
                from: Data(#"{"modelSessionIdentified":{"id":"sess"#.utf8)
            )
        } throws: { error in
            error is DecodingError
        }

        // The journaled session identity the resume path reads is intact.
        #expect(state.modelSession?.id == SessionID("session-1"))
        #expect(state.modelSession?.identity == SessionIdentity("fp-A"))
    }
}
