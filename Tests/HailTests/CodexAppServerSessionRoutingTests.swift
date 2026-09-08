import ScopedEffect
import Testing

@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Codex App Server session routing")
struct CodexAppServerSessionRoutingTests {
    @Test("native wire omits JSON-RPC header and encodes approval decisions")
    func nativeWireShape() throws {
        let request = CodexRPCRequest(
            id: 1,
            method: "initialize",
            params: CodexInitializeParams(
                clientInfo: .init(name: "hail", title: "Hail", version: "0.1.0"),
                capabilities: .init(experimentalApi: true)
            )
        )
        let requestObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(requestObject["jsonrpc"] == nil)
        #expect(requestObject["method"] as? String == "initialize")
        let capabilities = try #require(requestObject["params"] as? [String: Any])
        #expect((capabilities["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool == true)

        let response = CodexRPCResponse.approval(id: .number(7))
        let responseObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        let result = try #require(responseObject["result"] as? [String: Any])
        #expect(responseObject["jsonrpc"] == nil)
        #expect(responseObject["id"] as? Int == 7)
        #expect(result["decision"] as? String == "accept")

        let permissions = CodexRPCResponse.noPermissions(id: .number(8))
        let permissionsObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(permissions)) as? [String: Any]
        )
        let permissionsResult = try #require(permissionsObject["result"] as? [String: Any])
        let profile = try #require(permissionsResult["permissions"] as? [String: Any])
        let network = try #require(profile["network"] as? [String: Any])
        #expect(permissionsResult["scope"] as? String == "turn")
        #expect(network["enabled"] as? Bool == false)
    }

    @Test("warm turns reuse one process and identity changes start a new thread")
    func warmReuseAndIdentityChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-codex-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptLog = directory.appendingPathComponent("prompts.log")
        let requestsLog = directory.appendingPathComponent("requests.log")
        let launchesLog = directory.appendingPathComponent("launches.log")
        let stub = directory.appendingPathComponent("stub-codex.py")
        let script = """
            #!/usr/bin/env python3
            import sys, json
            with open(\(launchesLog.path.debugDescription), "a") as f:
                f.write("launch\\n")
            def send(value):
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method in ("thread/start", "thread/resume", "turn/start"):
                    with open(\(requestsLog.path.debugDescription), "a") as f:
                        f.write(json.dumps(message) + "\\n")
                if method == "initialize":
                    send({"id": message["id"], "result": {"userAgent": "stub", "platformFamily": "unix", "platformOs": "macos", "codexHome": "/tmp"}})
                elif method in ("thread/start", "thread/resume"):
                    send({"id": message["id"], "result": {"thread": {"id": "stub-codex-thread", "sessionId": "stub-codex-session"}}})
                elif method == "turn/start":
                    prompt = message["params"]["input"][0]["text"]
                    with open(\(promptLog.path.debugDescription), "a") as f:
                        f.write(prompt + "\\n<<<END>>>\\n")
                    # Exercise the race where events arrive before the turn/start response.
                    send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": "stub-codex-thread", "turnId": "turn-1", "itemId": "reasoning-1", "summaryIndex": 0, "delta": "Thinking"}})
                    send({"method": "item/agentMessage/delta", "params": {"threadId": "stub-codex-thread", "turnId": "turn-1", "itemId": "message-1", "delta": "OK"}})
                    send({"id": message["id"], "result": {"turn": {"id": "turn-1", "items": [], "status": "inProgress"}}})
                    send({"method": "item/completed", "params": {"threadId": "stub-codex-thread", "turnId": "turn-1", "completedAtMs": 0, "item": {"id": "message-1", "type": "agentMessage", "text": "OK"}}})
                    send({"method": "turn/completed", "params": {"threadId": "stub-codex-thread", "turn": {"id": "turn-1", "items": [], "status": "completed"}}})
            """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let endpoint = try CodexAppServerEndpoint(
            model: "gpt-test",
            workingDirectory: directory.path,
            mcpServerConfiguration: MCPServerConfiguration(
                name: "hail",
                command: "/Users/test/hail-cli",
                arguments: ["mcp"],
                agentIDEnvironmentKey: "HAIL_AGENT_ID"
            ),
            executablePath: stub.path,
            reasoningEffort: .xhigh
        )

        func turn(_ messages: [LLMMessage], _ delta: [LLMMessage], _ identity: String) async -> (
            String?, Bool
        ) {
            var output: String?
            var sawThinking = false
            for await event in endpoint.stream(
                input: ModelInput(messages: messages),
                delta: TurnDelta(
                    currentMessages: delta, workingMemory: [], sessionIdentity: SessionIdentity(identity)),
                authority: FullAuthority(),
                tools: nil,
                responseType: String.self
            ) {
                if case .generated(let value) = event { output = value }
                if case .thinking = event { sawThinking = true }
            }
            return (output, sawThinking)
        }

        let firstMessages = [
            LLMMessage(role: .system, content: "SYSTEM"),
            LLMMessage(role: .user, content: "FIRST"),
        ]
        let firstTurn = await turn(firstMessages, firstMessages, "identity-A")
        #expect(firstTurn.0 == "OK")
        #expect(firstTurn.1)
        let secondTurn = await turn(
            firstMessages + [
                LLMMessage(role: .assistant, content: "OK"),
                LLMMessage(role: .user, content: "SECOND"),
            ], [LLMMessage(role: .user, content: "SECOND")], "identity-A")
        #expect(secondTurn.0 == "OK")
        let thirdTurn = await turn(
            firstMessages,
            [LLMMessage(role: .user, content: "THIRD")],
            "identity-B"
        )
        #expect(thirdTurn.0 == "OK")
        await endpoint.terminateSession()

        let prompts = try String(contentsOf: promptLog, encoding: .utf8)
            .components(separatedBy: "<<<END>>>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let requests = try String(contentsOf: requestsLog, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }

        #expect(prompts.count == 3)
        let launches = try String(contentsOf: launchesLog, encoding: .utf8)
            .split(separator: "\n")
        #expect(launches.count == 1)
        #expect(requests.count == 5)
        #expect(prompts[0].contains("SYSTEM"))
        #expect(prompts[1].contains("SECOND"))
        #expect(!prompts[1].contains("SYSTEM"))
        #expect(requests[0]["method"] as? String == "thread/start")
        #expect(requests[1]["method"] as? String == "turn/start")
        let firstTurnParams = requests[1]["params"] as? [String: Any]
        #expect(firstTurnParams?["effort"] as? String == "xhigh")
        #expect(requests[2]["method"] as? String == "turn/start")
        #expect(requests[3]["method"] as? String == "thread/start")
        #expect(requests[4]["method"] as? String == "turn/start")
        #expect(requests.allSatisfy { $0["jsonrpc"] == nil })
        #expect(prompts[2].contains("SYSTEM"))

        let startParams = requests[0]["params"] as? [String: Any]
        let config = startParams?["config"] as? [String: Any]
        let servers = config?["mcp_servers"] as? [String: Any]
        let hail = servers?["hail"] as? [String: Any]
        #expect(hail?["command"] as? String == "/Users/test/hail-cli")
        #expect(hail?["args"] as? [String] == ["mcp"])
        #expect(hail?["env_vars"] as? [String] == ["HAIL_AGENT_ID"])
    }

    @Test("native command and file approvals are decided by the turn authority")
    func nativeEffectsUseTurnAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-codex-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decisionsLog = directory.appendingPathComponent("decisions.log")
        let turnsLog = directory.appendingPathComponent("turns.log")
        let stub = directory.appendingPathComponent("stub-codex.py")
        let script = """
            #!/usr/bin/env python3
            import sys, json
            turn = 0
            command_request = None
            file_request = None
            def send(value):
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
            def finish_turn():
                send({"method": "item/agentMessage/delta", "params": {"delta": "OK"}})
                send({"method": "item/completed", "params": {"item": {"id": "message", "type": "agentMessage", "text": "OK"}}})
                send({"method": "turn/completed", "params": {"turn": {"status": "completed"}}})
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    send({"id": message["id"], "result": {}})
                elif method == "thread/start":
                    send({"id": message["id"], "result": {"thread": {"id": "authority-thread", "sessionId": "authority-session"}}})
                elif method == "turn/start":
                    turn += 1
                    turn_id = "turn-%d" % turn
                    with open(\(turnsLog.path.debugDescription), "a") as f:
                        f.write(json.dumps(message["params"]) + "\\n")
                    send({"id": message["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
                    send({"method": "item/started", "params": {"threadId": "authority-thread", "turnId": turn_id, "item": {"id": "file-%d" % turn, "type": "fileChange", "changes": [{"path": "change-%d.txt" % turn}]}}})
                    command_request = 900 + turn * 2
                    file_request = command_request + 1
                    send({"id": command_request, "method": "item/commandExecution/requestApproval", "params": {"threadId": "authority-thread", "turnId": turn_id, "command": "swift test", "cwd": \(directory.path.debugDescription)}})
                elif command_request is not None and message.get("id") == command_request:
                    with open(\(decisionsLog.path.debugDescription), "a") as f:
                        f.write(message["result"]["decision"] + "\\n")
                    send({"id": file_request, "method": "item/fileChange/requestApproval", "params": {"threadId": "authority-thread", "turnId": turn_id, "itemId": "file-%d" % turn}})
                elif file_request is not None and message.get("id") == file_request:
                    with open(\(decisionsLog.path.debugDescription), "a") as f:
                        f.write(message["result"]["decision"] + "\\n")
                    finish_turn()
            """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let endpoint = try CodexAppServerEndpoint(
            model: "gpt-test",
            workingDirectory: directory.path,
            executablePath: stub.path
        )
        let messages = [LLMMessage(role: .user, content: "WORK")]

        func turn(authority: any Authority) async -> String? {
            var output: String?
            for await event in endpoint.stream(
                input: ModelInput(messages: messages),
                delta: TurnDelta(
                    currentMessages: messages,
                    workingMemory: [],
                    sessionIdentity: SessionIdentity("authority-test")
                ),
                authority: authority,
                tools: nil,
                responseType: String.self
            ) {
                if case .generated(let value) = event { output = value }
            }
            return output
        }

        #expect(await turn(authority: FullAuthority()) == "OK")
        #expect(await turn(authority: CompositeAuthority()) == "OK")
        await endpoint.terminateSession()

        let decisions = try String(contentsOf: decisionsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(decisions == ["accept", "accept", "decline", "decline"])

        let turns = try String(contentsOf: turnsLog, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0["approvalPolicy"] as? String == "on-request" })
        let grantedSandbox = turns[0]["sandboxPolicy"] as? [String: Any]
        let deniedSandbox = turns[1]["sandboxPolicy"] as? [String: Any]
        #expect(grantedSandbox?["type"] as? String == "readOnly")
        #expect(deniedSandbox?["type"] as? String == "readOnly")
        #expect(grantedSandbox?["networkAccess"] as? Bool == false)
        #expect(deniedSandbox?["networkAccess"] as? Bool == false)
        let grantedRoots = turns[0]["runtimeWorkspaceRoots"] as? [String]
        let deniedRoots = turns[1]["runtimeWorkspaceRoots"] as? [String]
        #expect(grantedRoots == [directory.path])
        #expect(deniedRoots == [])
    }

    /// The stub answers just enough to attach a thread and start a turn,
    /// then goes completely silent — a live-but-wedged app-server. Without
    /// the stall ceiling (`maxStallDuration`) this turn would hang forever.
    @Test("wedged app-server fails the turn at the stall ceiling")
    func wedgedServerFailsAtStallCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-codex-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-codex-wedged.py")
        let script = """
            #!/usr/bin/env python3
            import sys, json
            def send(value):
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    send({"id": message["id"], "result": {}})
                elif method == "thread/start":
                    send({"id": message["id"], "result": {"thread": {"id": "stall-thread", "sessionId": "stall-session"}}})
                elif method == "turn/start":
                    send({"id": message["id"], "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
                    # Wedged: no turn progress, no turn/completed, ever.
            """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

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
            maxStallDuration: 2
        )

        let start = Date()
        // The ceiling resets the connection, which finishes the turn's event
        // stream — surfacing as `.disconnected`, not just any error.
        await #expect {
            _ = try await session.runTurn(
                fullPrompt: "hello",
                deltaPrompt: nil,
                identity: nil,
                memorySnapshot: nil,
                outputSchema: nil,
                turnAuthority: nil,
                onNarration: { _ in }
            )
        } throws: { error in
            guard let sessionError = error as? CodexSessionError, case .disconnected = sessionError else {
                return false
            }
            return true
        }
        // The lower bound pins the failure to the 2s ceiling: an instant
        // failure would mean the turn died during bootstrap, not from the
        // watchdog. The upper bound stays far below the 1800s default.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 2)
        #expect(elapsed < 20)
        await session.terminate()
    }

    /// The stub starts a turn and never finishes it, so only consumer
    /// cancellation can end the turn — and cancellation must reach the
    /// *server*: without `turn/interrupt` the app-server turn keeps running,
    /// and the next warm turn on the reused thread would overlap it.
    @Test("cancelling a turn sends turn/interrupt to the app-server")
    func cancellationInterruptsServerTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-codex-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("requests.log")
        let stub = directory.appendingPathComponent("stub-codex.py")
        let script = """
            #!/usr/bin/env python3
            import sys, json
            def send(value):
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                with open(\(log.path.debugDescription), "a") as f:
                    f.write(json.dumps(message) + "\\n")
                if method == "initialize":
                    send({"id": message["id"], "result": {}})
                elif method == "thread/start":
                    send({"id": message["id"], "result": {"thread": {"id": "cancel-thread", "sessionId": "cancel-session"}}})
                elif method == "turn/start":
                    send({"id": message["id"], "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
                    # Never completes: only cancellation can end this turn.
                elif method == "turn/interrupt":
                    send({"id": message["id"], "result": {}})
            """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        // Generous stall ceiling: the watchdog must not interfere — only
        // consumer cancellation may end this turn.
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
            maxStallDuration: 60
        )

        let turn = Task {
            try await session.runTurn(
                fullPrompt: "hello",
                deltaPrompt: nil,
                identity: nil,
                memorySnapshot: nil,
                outputSchema: nil,
                turnAuthority: nil,
                onNarration: { _ in }
            )
        }

        // Cancel only once the turn is genuinely in flight, so the interrupt
        // targets a running server-side turn — the case that used to leak.
        #expect(await stubLog(log, contains: "turn/start"))
        turn.cancel()
        await #expect {
            _ = try await turn.value
        } throws: { error in
            guard let sessionError = error as? CodexSessionError, case .cancelled = sessionError else {
                return false
            }
            return true
        }
        // The interrupt is fire-and-forget, so poll for its arrival.
        #expect(await stubLog(log, contains: "\"turn/interrupt\""))
        #expect(await stubLog(log, contains: "\"turn-1\""))
        await session.terminate()
    }

    /// Polls the stub's log until it contains `needle` or the deadline
    /// passes. The stub writes asynchronously, so a single read could race
    /// the write. (Same helper as the ACP cancellation suite.)
    private func stubLog(_ log: URL, contains needle: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let data = try? Data(contentsOf: log),
                String(decoding: data, as: UTF8.self).contains(needle)
            {
                return true
            }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
