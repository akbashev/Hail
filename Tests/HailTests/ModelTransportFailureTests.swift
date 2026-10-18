import AnyLanguageModel
import Foundation
import HailCore
import HailModelRuntime
import HTTPTypes
import Testing

@Suite("Model transport failures")
struct ModelTransportFailureTests {
    @Test("a failed request is retried with the same transcript")
    func retriesRequest() async {
        let recorder = RequestRecorder()
        let model = FailingLanguageModel(recorder: recorder, failure: .timeoutOnce)
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "weather"))])),
            .toolCalls(
                .init([
                    .init(id: "call-1", toolName: "weather", arguments: GeneratedContent(properties: [:]))
                ])),
            .toolOutput(
                .init(id: "call-1", toolName: "weather", segments: [.text(.init(content: "7 degrees"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "It's 7 degrees."))])),
            .prompt(.init(segments: [.text(.init(content: "and tomorrow?"))])),
        ]
        let events = await collect(model, entries: entries)
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests.first.map { Array($0.prefix(entries.count - 1)) } == Array(entries.dropLast()))
        #expect(
            RequestContentHash.chain(tools: [], messages: requests[0])
                == RequestContentHash.chain(tools: [], messages: requests[1]))
        guard case .generated("done") = events.last else {
            Issue.record("Expected the generated value last")
            return
        }
        #expect(
            !events.contains {
                if case .failed = $0 { return true }
                return false
            })
    }

    @Test("transport retry is bounded")
    func failureStopsAfterOneRetry() async {
        let recorder = RequestRecorder()
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .timeoutAlways))
        #expect(await recorder.requests.count == 2)
        guard case .failed(.requestFailed) = events.last else {
            Issue.record("Expected a terminal request failure")
            return
        }
    }

    @Test("partial output prevents automatic replay")
    func partialOutputIsNotReplayed() async {
        let recorder = RequestRecorder()
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .afterPartial))
        #expect(await recorder.requests.count == 1)
        #expect(
            events.filter {
                if case .partialUpdated = $0 { return true }
                return false
            }.count == 1)
        guard case .failed(.requestFailed) = events.last else {
            Issue.record("Expected failure after partial output")
            return
        }
    }

    @Test("cancellation and decoding errors do not retry")
    func terminalErrorsDoNotRetry() async {
        for failure in [Failure.cancelled, .decoding] {
            let recorder = RequestRecorder()
            let events = await collect(FailingLanguageModel(recorder: recorder, failure: failure))
            #expect(await recorder.requests.count == 1)
            switch (failure, events.last) {
            case (.cancelled, .failed(.cancelled)), (.decoding, .failed(.decodingError("bad output"))): break
            default: Issue.record("Unexpected last event for \(failure)")
            }
        }
    }

    @Test("observed tool calls prevent replay even before a snapshot")
    func toolCallsAreNotReplayed() async {
        let recorder = RequestRecorder()
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .afterToolCall))
        #expect(await recorder.requests.count == 1)
        guard case .failed(.requestFailed) = events.last else {
            Issue.record("Expected failure after observing tool calls")
            return
        }
    }

    @Test("a busy provider is asked again after the wait it asks for")
    func busyProviderIsWaitedFor() async {
        let recorder = RequestRecorder()
        let busy = HTTPResponse(status: 429, headerFields: [.retryAfter: "0"])
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .http(busy, body: "slow down", times: 2)))
        #expect(await recorder.requests.count == 3)
        guard case .generated("done") = events.last else {
            Issue.record("Expected the generated value after waiting")
            return
        }
    }

    @Test("a provider that stays busy is waited for a few times")
    func busyProviderStopsBeingWaitedFor() async {
        let recorder = RequestRecorder()
        let overloaded = HTTPResponse(status: 529, headerFields: [.retryAfter: "0"])
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .http(overloaded, body: "overloaded", times: .max)))
        #expect(await recorder.requests.count == 4)
        #expect(events.last.map(isFailure(.unavailable)) == true)
    }

    @Test("a provider asking for a longer wait than is waited for fails at once", arguments: ["3600", "Fri, 01 Jan 2100 00:00:00 GMT"])
    func longWaitFails(retryAfter: String) async {
        let recorder = RequestRecorder()
        let busy = HTTPResponse(status: 429, headerFields: [.retryAfter: retryAfter])
        let events = await collect(FailingLanguageModel(recorder: recorder, failure: .http(busy, body: "", times: .max)))
        #expect(await recorder.requests.count == 1)
        #expect(events.last.map(isFailure(.rateLimit)) == true)
    }

    @Test("a request longer than the context is told by the provider's own words")
    func contextExceededIsReadInTheProvidersWords() async {
        let response = HTTPResponse(status: .badRequest)
        let body = #"{"error":{"code":400,"type":"exceed_context_size_error","n_prompt_tokens":3011,"n_ctx":256}}"#
        let ollama = await collect(
            FailingLanguageModel(recorder: RequestRecorder(), failure: .http(response, body: body, times: .max)),
            failures: .ollama)
        #expect(ollama.last.map(isFailure(.contextLengthExceeded)) == true)
        let anthropic = await collect(
            FailingLanguageModel(recorder: RequestRecorder(), failure: .http(response, body: body, times: .max)),
            failures: .anthropic)
        #expect(anthropic.last.map(isFailure(.requestFailed("HTTP 400: \(body)"))) == true)
    }

    @Test("a request the provider refuses to authorize is not asked again")
    func unauthorizedIsNotRetried() async {
        let recorder = RequestRecorder()
        let events = await collect(
            FailingLanguageModel(recorder: recorder, failure: .http(HTTPResponse(status: .unauthorized), body: "", times: .max)))
        #expect(await recorder.requests.count == 1)
        #expect(events.last.map(isFailure(.authentication)) == true)
    }

    private func isFailure(_ expected: ModelEndpointError) -> (ModelEvent<String>) -> Bool {
        { event in
            guard case .failed(let error) = event else { return false }
            return error == expected
        }
    }

    private func collect(
        _ model: FailingLanguageModel,
        entries: [Transcript.Entry] = [.prompt(.init(segments: [.text(.init(content: "hello"))]))],
        failures: ProviderFailures = .swiftErrors
    ) async -> [ModelEvent<String>] {
        let endpoint = AnyLanguageModelEndpoint(
            languageModel: model, modelIdentifier: "test", temperature: 0, failures: failures)
        var events: [ModelEvent<String>] = []
        for await event in endpoint.stream(
            request: ModelRequest(input: "input", entries: entries),
            tools: [], authority: FullAuthority(), generating: String.self, purpose: .generation
        ) {
            events.append(event)
            // Answered as the agent's session would.
            if case .toolCall(let toolCall) = event {
                toolCall.reply.give(
                    ToolAnswer(
                        result: ToolResult(toolCallID: toolCall.call.id, name: toolCall.call.name, output: .text("ok")),
                        tools: []))
            }
        }
        return events
    }
}

private enum Failure: Sendable {
    case timeoutOnce, timeoutAlways, afterPartial, cancelled, decoding, afterToolCall
    /// The provider answers with this error the first `times` requests.
    case http(HTTPResponse, body: String, times: Int)
}

private actor RequestRecorder {
    private(set) var requests: [[Transcript.Entry]] = []
    func record(_ entries: [Transcript.Entry]) -> Int {
        requests.append(entries)
        return requests.count
    }
}

private struct FailingLanguageModel: LanguageModel {
    let recorder: RequestRecorder
    let failure: Failure

    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw URLError(.unsupportedURL)
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<
            LanguageModelSession.ResponseStream<Content>.Snapshot, any Error
        > { continuation in
            let task = Task {
                do {
                    let attempt = await recorder.record(Array(session.transcript))
                    switch failure {
                    case .http(let response, let body, let times):
                        guard attempt > times else { throw HTTPTransportError.httpError(response: response, body: body) }
                        let raw = GeneratedContent("done")
                        continuation.yield(
                            .init(content: try Content(raw).asPartiallyGenerated(), rawContent: raw))
                        continuation.finish()
                        return
                    case .timeoutOnce where attempt > 1:
                        let raw = GeneratedContent("done")
                        continuation.yield(
                            .init(content: try Content(raw).asPartiallyGenerated(), rawContent: raw))
                        continuation.finish()
                        return
                    case .afterPartial:
                        let raw = GeneratedContent("partial")
                        continuation.yield(
                            .init(content: try Content(raw).asPartiallyGenerated(), rawContent: raw))
                    case .cancelled:
                        throw URLError(.cancelled)
                    case .decoding:
                        throw LanguageModelSession.GenerationError.decodingFailure(
                            .init(debugDescription: "bad output"))
                    case .afterToolCall:
                        let call = Transcript.ToolCall(
                            id: "new-call", toolName: "weather", arguments: GeneratedContent(properties: [:]))
                        await session.toolExecutionDelegate?.didGenerateToolCalls([call], in: session)
                        _ = await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session)
                    default: break
                    }
                    throw URLError(.timedOut)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(stream: stream)
    }
}
