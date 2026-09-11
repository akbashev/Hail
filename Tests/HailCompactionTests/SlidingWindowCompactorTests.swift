import AnyLanguageModel
import HailAgentRuntime
import HailCore
import Testing

@testable import HailCompaction

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("SlidingWindowCompactor")
struct SlidingWindowCompactorTests {
    private let agentID = AgentID(role: Role("scout"), contextID: AgentContextID("c1"))
    private let taskInstructions = PromptAssemblyInstructions(
        task: """
            Rules:
            1. Work ONLY on the task described in the user message.
            2. Do not write to files outside the workspace.
            3. Use the available tools to complete the task.
            """
    )

    // MARK: Helpers

    private func text(_ content: String, _ offset: TimeInterval) -> ChatMessage {
        .text(sender: "user", content: content, timestamp: Date(timeIntervalSince1970: offset))
    }

    private func context(
        thread: [ChatMessage],
        summary: GeneratedContent? = nil,
        memory: [String] = []
    ) throws -> PromptContext {
        PromptContext(
            agentID: agentID,
            definition: AgentDefinition(
                role: agentID.role,
                behavior: .init(
                    systemPrompt: "sys",
                    model: try AgentModel("test/fake")
                ),
            ),
            contextSummary: summary,
            conversationThread: thread,
            contextManifest: ContextManifest(items: []),
            instructions: taskInstructions
        )
    }

    private func preparedRequest(for context: PromptContext) -> PreparedRequest {
        assembleStandardPrompt(context)
    }

    private func text(in entry: Transcript.Entry) -> String {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let value):
            segments = value.segments
        case .prompt(let value):
            segments = value.segments
        case .response(let value):
            segments = value.segments
        case .toolCalls, .toolOutput:
            return ""
        }

        return segments.map { segment in
            switch segment {
            case .text(let value):
                return value.content
            case .structure(let value):
                return value.content.jsonString
            case .image:
                return "[image]"
            }
        }.joined(separator: "\n")
    }

    private func requireCompaction(
        _ decision: CompactionDecision<String>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CompactionResult<String> {
        guard case .compacted(let compaction) = decision else {
            Issue.record("Expected a compaction decision", sourceLocation: sourceLocation)
            throw TestFailure()
        }
        return compaction
    }

    /// A compactor with a request-sized 1,000-token window. The fixture uses a
    /// 15% soft threshold and reserves 400 tokens, leaving enough room for
    /// the assembled prompt and the retained suffix in this small fixture.
    private func makeCompactor(
        keepRecent: Int = 2,
        outputReserve: Int = 400
    ) -> SlidingWindowCompactor {
        SlidingWindowCompactor(
            threshold: 0.15,
            keepRecent: keepRecent,
            outputReserve: outputReserve,
            toolResultReserve: 0
        )
    }

    private func budget() throws -> CompactionBudget {
        try CompactionBudget(contextWindow: 1_000)
    }

    // MARK: Tests

    @Test("a context under the threshold compacts nothing")
    func underThresholdNoCompaction() async throws {
        let compactor = makeCompactor()
        // Two short messages: far below 70 tokens.
        let ctx = try context(thread: [text("hi", 0), text("hello", 1)])

        let result = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { _ in "unused" }
        #expect(result == .unchanged)
    }

    @Test("over threshold, the oldest messages are archived and the tail kept")
    func compactionArchivesPrefix() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        // 5 messages of 40 chars each ≈ 5 × 14 = 70 tokens → triggers.
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        #expect(result.output == "rolled")
        // The preferred tail is kept when it fits. Compaction archives the
        // complete older prefix, rather than stopping after an arbitrary
        // minimum amount of progress.
        #expect(result.archivedCount == 3)
    }

    @Test("an oversized archived message still uses one summarization request")
    func oversizedArchivedMessageUsesOneRequest() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        let thread = [
            text(String(repeating: "a", count: 12_000), 0),
            text("recent one", 1),
            text("recent two", 2),
        ]
        let calls = Box<Int>()
        calls.value = 0

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in
                calls.value = (calls.value ?? 0) + 1
                return "rolled"
            }
        )

        #expect(result.archivedCount == 1)
        #expect(calls.value == 1)
    }

    @Test("the existing rolling summary is folded into the summarize prompt")
    func priorSummaryFoldedIn() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let calls = Box<[[Transcript.Entry]]>()

        let ctx = try context(thread: thread, summary: GeneratedContent("v1"))
        _ = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { request in
            calls.value = (calls.value ?? []) + [request.entries]
            return "v2"
        }

        let prompts = try #require(calls.value)
        #expect(!prompts.isEmpty)
        #expect(
            prompts.contains {
                $0.contains { message in
                    let rendered = text(in: message)
                    return rendered.contains("Summary so far:") && rendered.contains("\"v1\"")
                }
            }
        )
    }

    @Test("the cut never splits a tool call from its result")
    func toolPairIntegrity() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        // Thread over threshold where the naive cut lands right after a
        // toolCall — its result would be orphaned in the kept suffix.
        let call = ToolCall(id: "1", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 40), 0),
            text(String(repeating: "b", count: 40), 1),
            text(String(repeating: "c", count: 40), 2),
            .toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 3)),
            .toolResult(
                id: "1", name: "read_file", output: .text("contents"), timestamp: Date(timeIntervalSince1970: 4)),
            text(String(repeating: "d", count: 40), 5),
        ]

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The preferred suffix contains the complete tool interaction, but it
        // is still too large for the retained request budget. The fallback
        // therefore archives that complete interaction as one unit and keeps
        // only the final semantic message.
        #expect(result.archivedCount == 3)
    }

    @Test("the current assistant tool-round representation stays paired with its result")
    func assistantToolRoundIntegrity() async throws {
        let compactor = makeCompactor(keepRecent: 2)
        let call = ToolCall(id: "1", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 40), 0),
            text(String(repeating: "b", count: 40), 1),
            text(String(repeating: "c", count: 40), 2),
            .assistantToolCall(
                round: ModelToolRound(
                    narration: Transcript.Response(
                        assetIDs: [],
                        segments: [.text(.init(content: "working"))]
                    ),
                    reasoning: [.text(.init(content: "checking"))],
                    calls: [call]
                ),
                timestamp: Date(timeIntervalSince1970: 3)
            ),
            .toolResult(
                id: "1",
                name: "read_file",
                output: .text("contents"),
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            text(String(repeating: "d", count: 40), 5),
        ]

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        #expect(result.archivedCount == 3)
    }

    @Test("the cut keeps every result of a parallel tool call with its call")
    func parallelToolResultsStayTogether() async throws {
        let compactor = makeCompactor(keepRecent: 2, outputReserve: 400)
        let first = ToolCall(id: "1", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let second = ToolCall(id: "2", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 80), 0),
            text(String(repeating: "b", count: 80), 1),
            .toolCall(calls: [first, second], timestamp: Date(timeIntervalSince1970: 2)),
            .toolResult(id: "1", name: "read_file", output: .text("first"), timestamp: Date(timeIntervalSince1970: 3)),
            .toolResult(id: "2", name: "read_file", output: .text("second"), timestamp: Date(timeIntervalSince1970: 4)),
            text(String(repeating: "c", count: 80), 5),
        ]

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )

        // The preferred suffix contains the complete parallel interaction,
        // but the rebuilt request does not fit. The fallback archives the
        // whole call/results group; it never leaves either result orphaned.
        #expect(result.archivedCount == 2)
    }

    @Test("the message opening the in-flight turn is never archived")
    func lastMessageNeverArchived() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }

        let ctx = try context(thread: thread)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget()
            ) { _ in "rolled" }
        )
        // The newest message is protected. The rebuilt request fits only
        // after the older five-message prefix has been summarized.
        #expect(result.archivedCount == 5)
    }

    @Test("context projection is separate from the generated compaction output")
    func contextProjectionIsPersistedSeparately() async throws {
        let compactor = makeCompactor(keepRecent: 1)
        let thread = (0..<6).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let ctx = try context(thread: thread)

        let decision: CompactionDecision<GeneratedContent> = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget(),
            summarize: { _ in GeneratedContent("complete report") },
            contextProjection: { _, _ in GeneratedContent("conversation context") },
            trigger: .threshold
        )
        let result: CompactionResult<GeneratedContent>
        guard case .compacted(let compacted) = decision else {
            Issue.record("Expected a compaction decision")
            throw TestFailure()
        }
        result = compacted

        #expect(result.output == GeneratedContent("complete report"))
        #expect(result.context == GeneratedContent("conversation context"))
    }

    @Test("nothing to archive when the whole thread fits the kept tail")
    func nothingToArchive() async throws {
        // Huge estimator weight via working memory, tiny thread.
        let compactor = makeCompactor(keepRecent: 10)
        let thread = [text("hi", 0), text("hello", 1)]
        let memory = [String(repeating: "m", count: 400)]  // 100 tokens → triggers

        let ctx = try context(thread: thread, memory: memory)
        let result = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget()
        ) { _ in
            "unused"
        }
        #expect(result == .unchanged)
    }

    @Test("endpoint token counter is used for candidate fitting")
    func endpointCounterFitsCandidates() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 800)
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let ctx = try context(thread: thread)
        let measuredCandidates = Box<[[Transcript.Entry]]>()

        let request = assembleStandardPrompt(ctx)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 500, source: .reported),
                measure: { candidate in
                    measuredCandidates.value =
                        (measuredCandidates.value ?? []) + [candidate.entries]
                    // Deliberately disagree with the character estimator: the exact
                    // tokenizer says each rendered message costs 40 tokens.
                    return RequestMeasurement(
                        tokenCount: candidate.entries.count * 40,
                        source: .reported
                    )
                },
                summarize: { _ in "rolled" },
                trigger: .threshold
            )
        )

        // The task prompt has two stable system messages. With a 200-token
        // retained target, the exact counter includes the newly inserted
        // summary and allows only the final thread message to remain.
        #expect(result.archivedCount == 4)
        #expect(
            measuredCandidates.value?.contains { messages in
                messages.contains {
                    let rendered = text(in: $0)
                    return rendered.contains("Earlier conversation, summarized:")
                        && rendered.contains("\"rolled\"")
                }
            } == true
        )
    }

    @Test("assistant narration stays attached to the following tool group")
    func assistantNarrationToolGroupIntegrity() async throws {
        let compactor = makeCompactor(keepRecent: 2, outputReserve: 760)
        let call = ToolCall(id: "1", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let thread: [ChatMessage] = [
            text(String(repeating: "a", count: 40), 0),
            .text(sender: agentID.rawValue, content: "I will inspect it.", timestamp: Date(timeIntervalSince1970: 1)),
            .toolCall(calls: [call], timestamp: Date(timeIntervalSince1970: 2)),
            .toolResult(
                id: "1", name: "read_file", output: .text("contents"), timestamp: Date(timeIntervalSince1970: 3)),
            text(String(repeating: "b", count: 40), 4),
            text(String(repeating: "c", count: 40), 5),
        ]
        let ctx = try context(thread: thread)

        let request = assembleStandardPrompt(ctx)
        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 500, source: .reported),
                measure: { candidate in
                    RequestMeasurement(
                        tokenCount: candidate.entries.count * 40,
                        source: .reported
                    )
                },
                summarize: { _ in "rolled" },
                trigger: .threshold
            )
        )

        // A cut after the narration would orphan the tool call. The preferred
        // suffix is semantically valid, but the rebuilt request is too large,
        // so the next valid boundary archives the complete group.
        #expect(result.archivedCount == 4)
    }

    @Test("reused tool IDs do not merge separate interactions")
    func repeatedToolIDsStaySeparate() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 400)
        let call1 = ToolCall(id: "repeat", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let call2 = ToolCall(id: "repeat", name: "read_file", arguments: GeneratedContent(properties: [:]))
        let thread: [ChatMessage] = [
            text("old", 0),
            .toolCall(calls: [call1], timestamp: Date(timeIntervalSince1970: 1)),
            .toolResult(
                id: "repeat", name: "read_file", output: .text("first"), timestamp: Date(timeIntervalSince1970: 2)),
            text("between", 3),
            .toolCall(calls: [call2], timestamp: Date(timeIntervalSince1970: 4)),
            .toolResult(
                id: "repeat", name: "read_file", output: .text("second"), timestamp: Date(timeIntervalSince1970: 5)),
            text("tail", 6),
        ]
        let ctx = try context(thread: thread)
        let request = assembleStandardPrompt(ctx)

        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: request,
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 900, source: .reported),
                measure: { candidate in
                    RequestMeasurement(
                        tokenCount: candidate.entries.count * 100,
                        source: .reported
                    )
                },
                summarize: { _ in "rolled" },
                trigger: .threshold
            )
        )

        // The first call/result pair is archivable independently. A global
        // ID-based range would incorrectly merge both rounds. The final
        // request budget nevertheless requires archiving both complete
        // interactions while retaining the final text message.
        #expect(result.archivedCount == 6)
    }

    @Test("a latest message that cannot fit produces no false compaction")
    func oversizedLatestMessageFailsForcedRecovery() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 850)
        let thread = [
            text("old", 0),
            text(String(repeating: "x", count: 12_000), 1),
        ]
        let ctx = try context(thread: thread)

        await #expect(throws: AgentRuntimeError.contextLengthExceeded) {
            try await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 1_000, source: .reported),
                measure: { candidate in
                    let hasOversizedTail = candidate.entries.contains {
                        text(in: $0).count > 10_000
                    }
                    return RequestMeasurement(
                        tokenCount: hasOversizedTail ? 1_000 : 1,
                        source: .reported
                    )
                },
                summarize: { _ in "rolled" },
                trigger: .contextLengthExceeded
            )
        }
    }

    @Test("a post-generation overrun on a threshold decision keeps the context unchanged")
    func thresholdOverrunKeepsContextUnchanged() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 400)
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let ctx = try context(thread: thread)

        let decision = try await compactor.compact(
            context: ctx,
            request: preparedRequest(for: ctx),
            budget: try budget(),
            measurement: RequestMeasurement(tokenCount: 500, source: .reported),
            measure: { candidate in
                // The kept tail fits the retained budget; the rebuilt request
                // with its projected summary does not.
                let includesSummary = candidate.entries.contains {
                    text(in: $0).contains("Earlier conversation, summarized:")
                }
                return RequestMeasurement(
                    tokenCount: includesSummary ? 900 : 500,
                    source: .reported
                )
            },
            summarize: { _ in "rolled" },
            trigger: .threshold
        )

        #expect(decision == .unchanged)
    }

    @Test("a post-generation overrun on a forced recovery propagates the typed overflow")
    func forcedRecoveryOverrunThrows() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 400)
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let ctx = try context(thread: thread)

        await #expect(throws: AgentRuntimeError.contextLengthExceeded) {
            try await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 500, source: .reported),
                measure: { candidate in
                    let includesSummary = candidate.entries.contains {
                        text(in: $0).contains("Earlier conversation, summarized:")
                    }
                    return RequestMeasurement(
                        tokenCount: includesSummary ? 900 : 500,
                        source: .reported
                    )
                },
                summarize: { _ in "rolled" },
                trigger: .contextLengthExceeded
            )
        }
    }

    @Test("the summarizer is capped by the budget left after the kept tail")
    func summarizeIsCappedByRemainingBudget() async throws {
        let compactor = makeCompactor(keepRecent: 1, outputReserve: 400)
        let thread = (0..<5).map { text(String(repeating: "a", count: 40), TimeInterval($0)) }
        let ctx = try context(thread: thread)
        let budgets = Box<[Int]>()

        let result = try requireCompaction(
            await compactor.compact(
                context: ctx,
                request: preparedRequest(for: ctx),
                budget: try budget(),
                measurement: RequestMeasurement(tokenCount: 500, source: .reported),
                measure: { _ in
                    // Both the kept tail and the rebuilt request fit the
                    // retained budget of 600, so the only limit left for the
                    // summary is 600 − 500 = 100 tokens.
                    RequestMeasurement(tokenCount: 500, source: .reported)
                },
                summarize: { request in
                    budgets.value = (budgets.value ?? []) + [request.maxOutputTokens]
                    return "rolled"
                },
                trigger: .threshold
            )
        )

        #expect(result.archivedCount == 4)
        #expect(budgets.value == [100])
    }
}

/// A tiny sendable box to capture closure outputs from the summarize hook.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

private struct TestFailure: Error {}
