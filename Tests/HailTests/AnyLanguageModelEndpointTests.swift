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

    @Test("text before tool calls is one narration segment, not one per delta")
    func narrationBeforeToolCallsIsOneSegment() async throws {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: ToolCallingLanguageModel(narration: ["Let", "Let me", "Let me check"]),
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
            if case .toolsRequested(let round) = event { requested = round }
        }

        let segments = try #require(requested?.narration?.segments)
        #expect(segments.count == 1)
        guard case .text(let text)? = segments.first else {
            Issue.record("The narration isn't text")
            return
        }
        #expect(text.content == "Let me check")
    }

    @Test("a request's reasoning override reaches the options through the endpoint's switch")
    func reasoningOverrideReachesOptions() async {
        let recorded = RecordedOptions()
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: OptionsRecordingLanguageModel(recorded: recorded),
            modelIdentifier: "test",
            temperature: 0.5,
            reasoningSwitch: .init { thinking, options in
                options.temperature = thinking == .enabled ? 1 : 0
            }
        )
        let entries: [Transcript.Entry] = [.prompt(.init(segments: [.text(.init(content: "hello"))]))]
        for reasoning in [ModelReasoningOverride.enabled, .disabled, .providerDefault] {
            for await _ in endpoint.stream(
                request: ModelRequest(input: "hello", entries: entries, reasoning: reasoning),
                tools: [],
                authority: FullAuthority(),
                generating: String.self,
                purpose: .generation
            ) {}
        }
        #expect(await recorded.temperatures == [1, 0, 0.5])
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
    /// Text streamed before the tool call, as cumulative snapshots.
    var narration: [String] = []

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
                for text in narration {
                    continuation.yield(
                        .init(
                            content: (text as! Content).asPartiallyGenerated(),
                            rawContent: GeneratedContent(text),
                            transcriptEntries: []
                        )
                    )
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

private actor RecordedOptions {
    private(set) var temperatures: [Double?] = []
    func record(_ options: GenerationOptions) { temperatures.append(options.temperature) }
}

/// Answers "ok", recording the options of each request.
private struct OptionsRecordingLanguageModel: LanguageModel {
    let recorded: RecordedOptions

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
        let recorded = recorded
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            let task = Task {
                await recorded.record(options)
                let content = "ok" as! Content
                continuation.yield(
                    .init(content: content.asPartiallyGenerated(), rawContent: GeneratedContent("ok"), transcriptEntries: []))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
