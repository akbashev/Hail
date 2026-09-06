import AnyLanguageModel
import HailCore
import HailModelRuntime
import Testing

struct AnyLanguageModelEndpointTests {
    @Test("plain text streaming forwards cumulative snapshots as deltas")
    func plainTextStreamingForwardsDeltas() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SnapshotLanguageModel(snapshots: ["hel", "hello"]),
            modelIdentifier: "test",
            temperature: 0
        )

        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil
        ) {
            events.append(event)
        }

        #expect(events == [
            .status("Generating..."),
            .text("hel"),
            .text("lo"),
            .generated("hello")
        ])
    }

    @Test("plain text contracts stream through typed chat responses")
    func typedChatResponseStreamingForwardsDeltas() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: SnapshotLanguageModel(snapshots: ["hel", "hello"]),
            modelIdentifier: "test",
            temperature: 0
        )

        var events: [ModelEvent<ChatResponse>] = []
        for await event in endpoint.stream(
            input: ModelInput(messages: [LLMMessage(role: .user, content: "hello")]),
            tools: nil,
            responseType: ChatResponse.self
        ) {
            events.append(event)
        }

        #expect(events == [
            .status("Generating..."),
            .text("hel"),
            .partialUpdated(ChatResponse(content: "hel")),
            .text("lo"),
            .partialUpdated(ChatResponse(content: "hello")),
            .generated(ChatResponse(content: "hello"))
        ])
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
                let content: Content
                if type == String.self {
                    content = text as! Content
                } else if type == ChatResponse.self {
                    content = ChatResponse(content: text) as! Content
                } else {
                    fatalError("Unsupported test output")
                }
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
