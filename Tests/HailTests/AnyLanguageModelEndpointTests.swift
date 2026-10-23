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

        func run(_ input: EffectInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            .text(input.message)
        }
    }

    private struct OtherTool: HailCore.Tool {
        let name = "other_tool"
        let description = "Offered after the first call."

        func effect(for input: EffectInput) throws -> ClockEffect {
            ClockEffect()
        }

        func run(_ input: EffectInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            .text(input.message)
        }
    }

    /// Answers a tool call as the agent's session does: with the call's result, and the tools the
    /// session offers now.
    private static func answer(_ toolCall: ModelToolCall, with text: String, offering tools: [AnyTool]) {
        toolCall.reply.give(
            ToolAnswer(
                result: ToolResult(toolCallID: toolCall.call.id, name: toolCall.call.name, output: .text(text)),
                tools: tools
            ))
    }

    @Test("plain text streaming preserves typed snapshots and deltas")
    func plainTextStreamingForwardsTypedEvents() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SnapshotLanguageModel(snapshots: ["hel", "hello"]),
            modelIdentifier: "test",
            temperature: 0,
            failures: .swiftErrors
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
            events.map(describe) == [
                "status Generating", "partial hel", "partial hello", "generated hello",
            ]
        )
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
            },
            failures: .swiftErrors
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

    /// A request whose model thinks its whole length without answering is asked again without
    /// thinking, whoever asks it; one that still doesn't answer fails as one that thought past its
    /// answer.
    @Test("a request that answers nothing is asked again without thinking")
    func aRequestThatAnswersNothingIsAskedAgainWithoutThinking() async {
        let entries: [Transcript.Entry] = [.prompt(.init(segments: [.text(.init(content: "hello"))]))]
        for (answersWithoutThinking, ending) in [(true, "generated ok"), (false, "failed thoughtPastAnswer")] {
            let recorded = RecordedOptions()
            let endpoint = AnyLanguageModelEndpoint(
                languageModel: GoingRoundLanguageModel(
                    recorded: recorded, answersWithoutThinking: answersWithoutThinking),
                modelIdentifier: "test",
                temperature: 0.5,
                // Thinking on is temperature 1 to the model, off is 0.
                reasoningSwitch: .init { thinking, options in
                    options.temperature = thinking == .enabled ? 1 : 0
                },
                failures: .swiftErrors
            )
            var events: [String] = []
            for await event in endpoint.stream(
                request: ModelRequest(input: "hello", entries: entries, reasoning: .enabled),
                tools: [],
                authority: FullAuthority(),
                generating: String.self,
                purpose: .generation
            ) {
                events.append(describe(event))
            }
            #expect(events.last == ending)
            #expect(await recorded.temperatures == [1, 0])
        }
    }

    @Test("text before a tool call isn't an answer: a model that writes nothing after its call fails")
    func textBeforeACallIsNotAnAnswer() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: ToolCallingLanguageModel(narration: ["Let me fix it."], answersAfterCall: false),
            modelIdentifier: "test",
            temperature: 0,
            failures: .swiftErrors
        )
        var last: ModelEvent<String>?
        for await event in endpoint.stream(
            request: ModelRequest(
                input: "fix it", entries: [.prompt(.init(segments: [.text(.init(content: "fix it"))]))]),
            tools: [AnyTool(EffectTool())],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            if case .toolCall(let toolCall) = event {
                Self.answer(toolCall, with: "saved", offering: [AnyTool(EffectTool())])
            }
            last = event
        }
        guard case .failed(.thoughtPastAnswer) = last else {
            Issue.record(
                "Expected the request to fail, not to answer with its text before the call: \(String(describing: last))"
            )
            return
        }
    }

    /// A call goes to the agent's session; the model goes on with the session's answer in the same
    /// request, and sees the tools the session offers after it.
    @Test("a tool call goes to the agent's session, and the request goes on with its answer")
    func toolCallsGoToTheSessionAndTheRequestGoesOn() async throws {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: ToolCallingLanguageModel(),
            modelIdentifier: "test",
            temperature: 0,
            failures: .swiftErrors
        )
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "use the tool"))]))
        ]
        var requested: [ModelToolCall] = []
        var generated: String?
        for await event in endpoint.stream(
            request: ModelRequest(input: "use the tool", entries: entries),
            tools: [AnyTool(EffectTool())],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            switch event {
            case .toolCall(let toolCall):
                requested.append(toolCall)
                Self.answer(toolCall, with: "the answer", offering: [AnyTool(EffectTool()), AnyTool(OtherTool())])
            case .generated(let value):
                generated = value
            default:
                break
            }
        }

        #expect(requested.map(\.call.id) == ["call-1"])
        #expect(requested.first?.call.name == "effect_test")
        #expect(generated == "the answer; now offered: effect_test, other_tool")
    }

    /// A request must answer a prompt: tool outputs are never followed by a new request.
    @Test("a request that doesn't end with a prompt fails, instead of sending an empty one")
    func requestWithoutPromptFails() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SnapshotLanguageModel(snapshots: ["unused"]),
            modelIdentifier: "test",
            temperature: 0,
            failures: .swiftErrors
        )
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "use the tool"))])),
            .toolOutput(.init(id: "call-1", toolName: "effect_test", segments: [.text(.init(content: "done"))])),
        ]
        var failed = false
        for await event in endpoint.stream(
            request: ModelRequest(input: "use the tool", entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: String.self,
            purpose: .generation
        ) {
            if case .failed = event { failed = true }
        }
        #expect(failed)
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
    /// Whether it writes anything once the call is answered.
    var answersAfterCall = true

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
                // Goes on with the decided output, in the same request, with the tools resolved again.
                guard
                    case .provideOutput(let segments)? = await session.toolExecutionDelegate?.toolCallDecision(
                        for: call, in: session)
                else {
                    continuation.finish()
                    return
                }
                guard answersAfterCall else {
                    // The round's snapshot, as a provider gives one after its calls are answered.
                    let text = narration.last ?? ""
                    continuation.yield(
                        .init(
                            content: (text as! Content).asPartiallyGenerated(),
                            rawContent: GeneratedContent(text),
                            transcriptEntries: [.toolCalls(.init([call]))]
                        )
                    )
                    continuation.finish()
                    return
                }
                let output = segments.map(\.description).joined()
                let offered = session.resolvedRequestContext().tools.map(\.name).sorted().joined(separator: ", ")
                let text = "\(output); now offered: \(offered)"
                continuation.yield(
                    .init(
                        content: (text as! Content).asPartiallyGenerated(),
                        rawContent: GeneratedContent(text),
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
                    .init(
                        content: content.asPartiallyGenerated(), rawContent: GeneratedContent("ok"),
                        transcriptEntries: []))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

/// A model event as a test reads it: events carry a reply for tool calls, so they aren't values
/// to compare.
private func describe(_ event: ModelEvent<String>) -> String {
    switch event {
    case .activity(.status(let content)): "status \(text(content))"
    case .activity(.reasoningDelta(let content)): "reasoning \(text(content))"
    case .partialUpdated(let content): "partial \(text(content))"
    case .generated(let value): "generated \(value)"
    case .toolCall(let toolCall): "call \(toolCall.call.name)"
    case .usage: "usage"
    case .contextUsage: "context usage"
    case .failed(let error): "failed \(error)"
    }
}

private func text(_ content: GeneratedContent) -> String {
    if case .string(let value) = content.kind { return value }
    return content.jsonString
}

/// A model that goes round its thoughts with thinking on, answering nothing, and answers with it
/// off, when `answersWithoutThinking`.
private struct GoingRoundLanguageModel: LanguageModel {
    let recorded: RecordedOptions
    let answersWithoutThinking: Bool

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
        let answer = options.temperature == 0 && answersWithoutThinking ? "ok" : ""
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            let task = Task {
                await recorded.record(options)
                let content = answer as! Content
                continuation.yield(
                    .init(
                        content: content.asPartiallyGenerated(), rawContent: GeneratedContent(answer),
                        transcriptEntries: []))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
