import AnyLanguageModel
import HailCore
import Testing

@testable import HailModelRuntime

@Suite("Asking a model again")
struct RequestAttemptsTests {
    private let busy = RequestAttempts.Ending.failed(.busy(.rateLimit, retryAfter: .seconds(2)))
    private let unreached = RequestAttempts.Ending.failed(.unreached(.requestFailed("timed out")))

    @Test("a request that didn't reach the model is asked again once")
    func unreachedIsAskedAgainOnce() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        #expect(attempts.next(after: unreached, progress: .notStarted) == .askAgain(after: .seconds(1)))
        #expect(attempts.next(after: unreached, progress: .notStarted) == .fail(.requestFailed("timed out")))
    }

    @Test("a busy provider is waited for as it asks, a few times")
    func busyIsWaitedForAFewTimes() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        for _ in 0..<RequestAttempts.mostBusyWaits {
            #expect(attempts.next(after: busy, progress: .notStarted) == .askAgain(after: .seconds(2)))
        }
        #expect(attempts.next(after: busy, progress: .notStarted) == .fail(.rateLimit))
    }

    @Test("a busy provider that doesn't say how long is waited for the usual time, and one asking too long isn't")
    func busyWaits() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        #expect(
            attempts.next(after: .failed(.busy(.unavailable, retryAfter: nil)), progress: .notStarted)
                == .askAgain(after: RequestAttempts.usualWait))
        #expect(
            attempts.next(after: .failed(.busy(.unavailable, retryAfter: .seconds(3600))), progress: .notStarted)
                == .fail(.unavailable))
    }

    @Test("a request under way isn't asked again", arguments: [RequestProgress.answering, .calledTools])
    func underWayIsNotAskedAgain(progress: RequestProgress) {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        #expect(attempts.next(after: busy, progress: progress) == .fail(.rateLimit))
        #expect(attempts.next(after: unreached, progress: progress) == .fail(.requestFailed("timed out")))
    }

    @Test("a model that wrote nothing is asked once more, without thinking")
    func wroteNothingIsAskedWithoutThinking() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        #expect(attempts.next(after: .wroteNothing, progress: .answering) == .askAgain(after: .zero))
        #expect(attempts.thinking == .disabled)
        #expect(attempts.next(after: .wroteNothing, progress: .answering) == .fail(.thoughtPastAnswer))
    }

    @Test("a model that wrote nothing after its tools ran fails: asked again, they'd run again")
    func wroteNothingAfterToolsFails() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: true)
        #expect(attempts.next(after: .wroteNothing, progress: .calledTools) == .fail(.thoughtPastAnswer))
    }

    @Test("a model whose thinking can't be turned off fails when it wrote nothing")
    func wroteNothingWithoutASwitchFails() {
        var attempts = RequestAttempts(thinking: .providerDefault, thinkingCanBeTurnedOff: false)
        #expect(attempts.next(after: .wroteNothing, progress: .notStarted) == .fail(.thoughtPastAnswer))
    }

    @Test("the final request's context and the session's usage reach the turn")
    func contextUsageIsReported() async {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: UsageReportingLanguageModel(),
            modelIdentifier: "test",
            temperature: 0,
            effectiveContextWindow: 1000,
            failures: .swiftErrors
        )
        var context: ContextUsage?
        var usage: ModelUsage?
        for await event in endpoint.stream(
            request: ModelRequest(input: "hi", entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))]),
            tools: [], authority: FullAuthority(), generating: String.self, purpose: .generation
        ) {
            if case .contextUsage(let reported) = event { context = reported }
            if case .usage(let reported) = event { usage = reported }
        }
        #expect(context == ContextUsage(usedTokens: 400, limitTokens: 1000, source: .reported))
        #expect(usage?.inputTokens == 400)
    }
}

/// Answers once, with 400 tokens of input in its final request.
private struct UsageReportingLanguageModel: LanguageModel {
    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        fatalError("The streaming test should not call respond")
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let raw = GeneratedContent("hello")
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            continuation.yield(
                .init(
                    content: try! Content(raw).asPartiallyGenerated(),
                    rawContent: raw,
                    transcriptEntries: [],
                    usage: .init(
                        input: .init(totalTokenCount: 400, cachedTokenCount: 0),
                        output: .init(totalTokenCount: 5, reasoningTokenCount: 0))
                ))
            continuation.finish()
        }
        return .init(stream: stream)
    }
}
