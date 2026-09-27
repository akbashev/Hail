import AnyLanguageModel
import HailCore
import ScopedEffect
import Testing

@testable import HailModelRuntime

@Suite("AnyLanguageModel endpoint")
struct AnyLanguageModelEndpointTests {
    @Generable
    struct EffectInput: Sendable {
        let message: String
    }

    private struct EffectTool: HailCore.Tool {
        let name = "effect_test"
        let description = "Tests the AnyLanguageModel tool bridge."

        func effect(for input: EffectInput) throws -> ClockEffect {
            ClockEffect()
        }

        func runOutput(
            input: EffectInput,
            token: borrowing EffectToken<ClockEffect>
        ) async throws -> ToolOutput {
            .text(input.message)
        }
    }

    @Test("AnyLanguageModel tool calls execute the authorized Hail effect")
    func authorizedToolCallExecutesEffect() async throws {
        let tool = AuthorizedAnyLanguageModelTool(
            tool: AnyTool(EffectTool()),
            authority: FullAuthority()
        )

        let output = try await tool.call(
            arguments: GeneratedContent(properties: ["message": "through the effect"])
        )

        #expect(output == GeneratedContent("through the effect"))
    }

    @Test("plain text streaming preserves typed snapshots and deltas")
    func plainTextStreamingForwardsTypedEvents() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SnapshotLanguageModel(snapshots: ["hel", "hello"]),
            modelIdentifier: "test",
            temperature: 0
        )

        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "hello"))]))
        ]
        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "hello", entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            events.append(event)
        }

        #expect(
            events == [
                .activity(.status(GeneratedContent("Generating"))),
                .activity(.narrationDelta(GeneratedContent("hel"))),
                .partialUpdated("hel"),
                .activity(.narrationDelta(GeneratedContent("lo"))),
                .partialUpdated("hello"),
                .generated("hello"),
            ]
        )
    }

    @Test("streamed tool calls return to Hail for execution")
    func streamedToolCallsReturnToHail() async throws {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: ToolCallingLanguageModel(),
            modelIdentifier: "test",
            temperature: 0
        )
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "use the tool"))]))
        ]
        var requested: ModelToolRound?

        for await event in endpoint.stream(
            request: ModelRequest(input: "use the tool", entries: entries),
            tools: [AnyTool(EffectTool())],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            if case .toolsRequested(let round) = event {
                requested = round
            }
        }

        let round = try #require(requested)
        #expect(round.calls.count == 1)
        #expect(round.calls.first?.id == "call-1")
        #expect(round.calls.first?.name == "effect_test")
    }
}

private struct SnapshotLanguageModel: LanguageModel {
    let snapshots: [String]

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        fatalError("The streaming test should not call respond")
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            for text in snapshots {
                guard type == String.self else {
                    fatalError("Unsupported test output")
                }
                let content = text as! Content
                continuation.yield(
                    .init(
                        content: content.asPartiallyGenerated(),
                        rawContent: GeneratedContent(text)
                    )
                )
            }
            continuation.finish()
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private struct ToolCallingLanguageModel: LanguageModel {
    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        fatalError("The streaming test should not call respond")
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            let task = Task {
                guard type == String.self else {
                    fatalError("Unsupported test output")
                }
                let call = Transcript.ToolCall(
                    id: "call-1",
                    toolName: "effect_test",
                    arguments: GeneratedContent(properties: ["message": "hello"])
                )
                await session.toolExecutionDelegate?.didGenerateToolCalls([call], in: session)
                _ = await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session)
                let content = "" as! Content
                continuation.yield(
                    .init(
                        content: content.asPartiallyGenerated(),
                        rawContent: GeneratedContent(""),
                        transcriptEntries: [.toolCalls(.init([call]))]
                    )
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
