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
@Suite("ReasoningLoop cancellation mapping")
struct ReasoningLoopCancellationTests {
    @Test("cancellation closes the turn as cancelled, not failed")
    func cancellationClosesAsCancelled() {
        let at = Date(timeIntervalSince1970: 1)
        #expect(TurnEnd(CancellationError()) == .cancelled)
        #expect(TurnEnd(AgentRuntimeError.cancelled) == .cancelled)
        #expect(TurnEnd(CancellationError()).event(at: at) == .cancelled(at: at))
    }

    @Test("genuine failures close the turn as failed")
    func failuresCloseAsFailed() {
        let at = Date(timeIntervalSince1970: 1)
        #expect(TurnEnd(AgentRuntimeError.rateLimit).event(at: at) == .failed(.init(error: .rateLimit, at: at)))

        struct UnexpectedError: Error {}
        guard case .failed(.infrastructureFailure) = TurnEnd(UnexpectedError()) else {
            Issue.record("unexpected errors must wrap as infrastructureFailure")
            return
        }
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
        let first = try TurnCalls(limit: 8).resulted(failure)
        #expect(throws: AgentRuntimeError.self) { try first.resulted(failure) }
        _ = try first.resulted(
            try result(
                id: "call-3",
                output: "Error: tool timer received invalid arguments at trigger: expected object; found array"
            ))
    }

    @Test("a turn's tool calls stop at its limit")
    func toolCallsAreLimited() throws {
        let one = try TurnCalls(limit: 1).calling()
        #expect(throws: AgentRuntimeError.toolCallsRanOut(limit: 1)) {
            try one.calling()
        }
    }

    @Test("transient tool failures do not trigger the deterministic failure guard")
    func transientToolFailuresAreNotBoundedAsInvalidArguments() throws {
        let failure = ToolResult(
            toolCallID: "call-1",
            name: "web_search",
            output: .text("Error: service unavailable"),
            failureKind: .unavailable
        )
        _ = try TurnCalls(limit: 8).resulted(failure).resulted(failure).resulted(failure)
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

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
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

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
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

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            .text("ok")
        }
    }

    @Test("a cancelled tool aborts the round instead of becoming a ToolResult")
    func cancellationPropagates() async {
        var registry = AgentSession()
        registry.register(CancellationThrowingTool())

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
        var registry = AgentSession()
        registry.register(FailingTool())

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
        var registry = AgentSession()
        registry.register(NestedInputTool())

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
        #expect(results[0].output.textRepresentation.contains("`trigger` is `\"not-an-object\"`, but it's an object"))
    }
}
