import AnyLanguageModel
import HailCore
import ScopedEffect
import Testing

@testable import HailAgentRuntime
@testable import HailModelRuntime

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Cancelling the consumer of a prompt stream must reach the harness: without
/// a `session/cancel` notification the agent keeps executing fs/terminal
/// effects after Hail considers the turn over, and the next turn's warm delta
/// interleaves into the still-running prompt in the same session.
///
/// The stub speaks just enough JSON-RPC to pass `initialize` and
/// `session/new` (same pattern as the stall-watchdog suite), logs every line
/// it receives, and never answers `session/prompt` — so the prompt can only
/// end through cancellation.
@Suite("ACPSession cancellation")
struct ACPSessionCancellationTests {
    private let stubScript = """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$1"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
          [ -z "$id" ] && continue
          case "$line" in
            *'"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\\n' "$id" ;;
            *'"session/new"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"cancel-session"}}\\n' "$id" ;;
          esac
        done
        """

    /// Polls the stub's log until it contains `needle` or the deadline
    /// passes. The stub writes asynchronously, so a single read could race
    /// the write.
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

    @Test("consumer cancellation sends session/cancel and ends the stream promptly")
    func consumerCancellationNotifiesHarness() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-agent.sh")
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let log = directory.appendingPathComponent("stub.log")

        // Generous stall settings: the watchdog must not interfere — only
        // consumer cancellation may end this turn.
        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path, log.path],
            stallTimeout: 60,
            probeTimeout: 60,
            maxStallDuration: 300
        )

        let (stream, _) = try await session.executePrompt("hello")
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // The stream fails once the session is torn down; the error
                // itself is not what this test asserts.
            }
        }

        // Cancel only once the prompt is genuinely in flight, so the harness
        // receives session/cancel mid-prompt — the case that used to leak.
        #expect(await stubLog(log, contains: "session/prompt"))

        let start = Date()
        consumer.cancel()
        await consumer.value
        // The stub never answers the prompt, so a prompt stream end proves
        // cancellation propagated — not that the turn finished naturally.
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await stubLog(log, contains: "session/cancel"))

        await session.terminate()
    }

    /// A cancelled prompt may still be running harness-side when the next
    /// turn arrives (`session/cancel` is not reliably observed mid-turn), so
    /// that next turn must cold-bootstrap — not warm-delta into the same
    /// session. Cold bootstrap relaunches the harness, visible in the stub
    /// log as a second `initialize`.
    @Test("the prompt after a cancellation cold-bootstraps instead of warm-deltaing")
    func nextPromptAfterCancellationColdStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-cancel-cold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub-agent.sh")
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let log = directory.appendingPathComponent("stub.log")

        let session = try ACPSession(
            model: "",
            workingDirectory: directory.path,
            agentPath: "/bin/sh",
            agentArguments: [stub.path, log.path],
            stallTimeout: 60,
            probeTimeout: 60,
            maxStallDuration: 300
        )
        let identity = SessionIdentity("cancel-cold-start")

        let (stream, _) = try await session.executeTurnPrompt(
            bootstrap: "hello", delta: "hello", identity: identity)
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Torn down out from under the consumer; not asserted here.
            }
        }
        #expect(await stubLog(log, contains: "session/prompt"))
        consumer.cancel()
        await consumer.value

        // Same identity: without the cancellation mark this would take the
        // warm path. The mark is set synchronously in the stream's
        // onTermination, so by the time the consumer has ended the decision
        // is already forced — no settling wait is needed here.
        _ = try await session.executeTurnPrompt(
            bootstrap: "again", delta: "again", identity: identity)

        // The second prompt reached a *new* harness process.
        #expect(await stubLog(log, contains: "again"))
        let contents = try String(contentsOf: log, encoding: .utf8)
        let initializes = contents.components(separatedBy: .newlines)
            .filter { $0.contains("\"initialize\"") }
        #expect(initializes.count == 2)

        await session.terminate()
    }
}

/// A cancelled turn is the caller abandoning the work, not a failure: it must
/// map to `AgentRuntimeError.cancelled` and must not be emitted as `turnFailed`.
/// The loop keeps this decision in one pure boundary function so lifecycle
/// handling does not spread across the model/tool transitions.
@Suite("ReasoningLoop cancellation mapping")
struct ReasoningLoopCancellationTests {
    @Test("cancellation maps to .cancelled and bypasses turnFailed emission")
    func cancellationBypassesFailureEmission() {
        let raw = ReasoningLoop<ContinuousClock>.mapTurnError(CancellationError())
        #expect(raw.mapped == .cancelled)
        #expect(!raw.emitsFailure)

        let endpointReported = ReasoningLoop<ContinuousClock>.mapTurnError(AgentRuntimeError.cancelled)
        #expect(endpointReported.mapped == .cancelled)
        #expect(!endpointReported.emitsFailure)
    }

    @Test("genuine failures still emit turnFailed")
    func failuresStillEmit() {
        let rateLimit = ReasoningLoop<ContinuousClock>.mapTurnError(AgentRuntimeError.rateLimit)
        #expect(rateLimit.mapped == .rateLimit)
        #expect(rateLimit.emitsFailure)

        struct UnexpectedError: Error {}
        let wrapped = ReasoningLoop<ContinuousClock>.mapTurnError(UnexpectedError())
        guard case .infrastructureFailure = wrapped.mapped else {
            Issue.record("unexpected errors must wrap as infrastructureFailure, got \(wrapped.mapped)")
            return
        }
        #expect(wrapped.emitsFailure)
    }

    @Test("repeated identical tool failures stop after one correction attempt")
    func repeatedToolFailuresAreBounded() throws {
        func result(id: String, output: String) throws -> ToolResult {
            ToolResult(
                toolCallID: id,
                name: "timer",
                output: .text(output),
                failureKind: .invalidArguments
            )
        }

        let failure = try result(
            id: "call-1",
            output: "Error: tool timer received invalid arguments at trigger: expected object; found string"
        )
        let tracker = ToolFailureTracker()

        let first = tracker.recording(results: [failure])
        let second = first.tracker.recording(results: [failure])
        let changed = second.tracker.recording(results: [
            try result(
                id: "call-3",
                output: "Error: tool timer received invalid arguments at trigger: expected object; found array"
            )
        ])
        #expect(!first.repeated)
        #expect(second.repeated)
        #expect(!changed.repeated)
    }

    @Test("transient tool failures do not trigger the deterministic failure guard")
    func transientToolFailuresAreNotBoundedAsInvalidArguments() throws {
        let failure = ToolResult(
            toolCallID: "call-1",
            name: "web_search",
            output: .text("Error: service unavailable"),
            failureKind: .unavailable
        )
        let tracker = ToolFailureTracker()

        let first = tracker.recording(results: [failure])
        let second = first.tracker.recording(results: [failure])
        let third = second.tracker.recording(results: [failure])
        #expect(!first.repeated)
        #expect(!second.repeated)
        #expect(!third.repeated)
    }
}

/// A tool that throws `CancellationError` — standing in for a tool awaiting a
/// resource when the turn is aborted — must abort the tool round, not become
/// a model-visible error that lets the round continue.
@Suite("ToolRegistry cancellation")
struct ToolRegistryCancellationTests {
    @Tool
    struct CancellationThrowingTool {
        @Generable
        struct Input: Sendable {}

        let name = "cancellation_throwing_tool"
        let description = "Always throws CancellationError when executed."

        var schema: ToolDefinition {
            TestToolDefinition.empty(name: name, description: description)
        }

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> ToolOutput {
            throw CancellationError()
        }
    }

    @Tool
    struct FailingTool {
        @Generable
        struct Input: Sendable {}

        let name = "failing_tool"
        let description = "Always fails with an ordinary tool error."

        var schema: ToolDefinition {
            TestToolDefinition.empty(name: name, description: description)
        }

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> ToolOutput {
            throw ToolError.notConfigured("test")
        }
    }

    @Tool
    struct NestedInputTool {
        @Generable
        struct Trigger: Sendable {
            let value: String
        }

        @Generable
        struct Input: Sendable {
            let trigger: Trigger
        }

        let name = "nested_input_tool"
        let description = "Requires an object in trigger."

        var schema: ToolDefinition {
            TestToolDefinition.empty(name: name, description: description)
        }

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(input: Input, token: borrowing EffectToken<ClockEffect>) async throws -> ToolOutput {
            .text("ok")
        }
    }

    @Test("a cancelled tool aborts the round instead of becoming a ToolResult")
    func cancellationPropagates() async {
        let registry = ToolRegistry()
        await registry.register(CancellationThrowingTool())

        await #expect(throws: AgentRuntimeError.cancelled) {
            _ = try await registry.execute([
                ToolCall(
                    id: "call-1",
                    name: "cancellation_throwing_tool",
                    arguments: GeneratedContent(properties: [:])
                )
            ])
        }
    }

    @Test("ordinary tool errors still become model-visible ToolResults")
    func ordinaryErrorsStillBecomeToolResults() async throws {
        let registry = ToolRegistry()
        await registry.register(FailingTool())

        let results = try await registry.execute([
            ToolCall(
                id: "call-1",
                name: "failing_tool",
                arguments: GeneratedContent(properties: [:])
            )
        ])
        try #require(results.count == 1)
        #expect(results[0].isError)
        #expect(results[0].failureKind == .unavailable)
    }

    @Test("decoding failures are classified as invalid arguments")
    func decodingFailureIdentifiesArgumentPath() async throws {
        let registry = ToolRegistry()
        await registry.register(NestedInputTool())

        let results = try await registry.execute([
            ToolCall(
                id: "call-1",
                name: "nested_input_tool",
                arguments: GeneratedContent(properties: ["trigger": "not-an-object"])
            )
        ])

        try #require(results.count == 1)
        #expect(results[0].isError)
        #expect(results[0].failureKind == .invalidArguments)
        #expect(results[0].output.textRepresentation.contains("expected Trigger"))
    }
}
