import AnyLanguageModel
import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Tool registry request stability")
struct ToolRegistryTests {
    @Generable
    struct GenericReport<Summary: Generable, Memory: Generable>: Sendable {
        let summary: Summary
        let memories: [Memory]
    }

    @Generable
    struct GenericSummary: Sendable {
        let text: String
    }

    @Generable
    struct GenericMemory: Sendable {
        let value: String
    }

    @Test("generic generable reports synthesize")
    func genericGenerableReport() throws {
        let content = GeneratedContent(properties: [
            "summary": GeneratedContent(properties: ["text": "done"]),
            "memories": GeneratedContent(elements: [
                GeneratedContent(properties: ["value": "Haar"])
            ]),
        ])
        let report = try GenericReport<GenericSummary, GenericMemory>(content)
        #expect(report.summary.text == "done")
        #expect(report.memories.map { $0.value } == ["Haar"])
    }

    @Test("schemas are sorted independently of registration order")
    func schemasHaveStableOrder() async {
        var registry = AgentSession()
        registry.register(NowTool())
        registry.register(FileTool(projectRoot: URL(fileURLWithPath: "/tmp")))

        let names = registry.schemas().map(\.name)

        #expect(names == ["file", "now"])
    }

    struct GeneratedInputTool: HailCore.Tool {
        @Generable
        struct Input: Sendable {
            let message: String
        }

        let name = "generated_input"
        let description = "Echoes generated arguments."

        func effect(for input: Input) throws -> ClockEffect {
            ClockEffect()
        }

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            .text(input.message)
        }
    }

    @Tool("test")
    struct ParameterlessCommands {
        @Command("ping", description: "Check that the command is reachable.")
        func ping() -> ClockEffect {
            ClockEffect()
        }

        func render(_ date: Date) -> ToolOutput {
            .text(date.ISO8601Format())
        }
    }

    @Test("a call to a tool that doesn't exist lists the tools, with what each does")
    func unknownToolListsTheTools() async throws {
        var registry = AgentSession()
        registry.register(tools: ParameterlessCommands().tools)
        let results = try await registry.execute([
            ToolCall(id: "1", name: "test", arguments: GeneratedContent(properties: [:]))
        ])

        #expect(results[0].failureKind == .rejected)
        #expect(
            results[0].output.textRepresentation
                == "Error: There's no tool `test`. The tools are:\n- test_ping: Check that the command is reachable.")
    }

    @Test("each command is given by the name it's declared with, as its tool")
    func commandsAreGivenByTheirNames() {
        let commands = ParameterlessCommands().commands

        #expect(Array(commands.keys) == ["ping"])
        #expect(commands["ping"]?.name == "test_ping")
    }

    @Test("parameterless commands receive an empty generated input")
    func parameterlessCommand() async throws {
        let tool = ParameterlessCommands.PingTool(owner: ParameterlessCommands())

        #expect(tool.description == "Check that the command is reachable.")
        let output = try await AnyTool(tool).runOutput(
            generatedContent: GeneratedContent(properties: [:]),
            authority: FullAuthority()
        )
        #expect(!output.result.textRepresentation.isEmpty)
    }

    /// A tool that links to the generated-input tool, as a page links to the next one.
    struct LinkingTool: HailCore.Tool {
        typealias Input = EmptyToolInput
        let name = "start"
        let description = "Starts, and links to what comes next."

        func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            .text("Started.", links: [GeneratedInputTool()])
        }
    }

    @Test("a result's links are offered in its call's scope, first; calling another tool leaves it open, like a tab")
    func linksAreOffered() async throws {
        var registry = AgentSession()
        registry.register(tools: [LinkingTool(), NowTool()])
        #expect(registry.schemas().map(\.name) == ["now", "start"])

        let results = try await registry.execute([
            ToolCall(id: "1", name: "start", arguments: GeneratedContent(properties: [:]))
        ])
        #expect(results[0].output.textRepresentation == "Started.")
        #expect(registry.schemas().map(\.name) == ["generated_input", "now", "start"])

        let echoed = try await registry.execute([
            ToolCall(id: "2", name: "generated_input", arguments: GeneratedContent(properties: ["message": "hi"]))
        ])
        #expect(echoed[0].output == .text("hi"))

        _ = try await registry.execute([ToolCall(id: "3", name: "now", arguments: GeneratedContent(properties: [:]))])
        #expect(registry.schemas().map(\.name) == ["generated_input", "now", "start"])
    }

    /// Builds a list of names with the model, a call at a time: the names are a local of its
    /// scope, and making the list is its result.
    struct ListTool: HailCore.Tool {
        typealias Input = EmptyToolInput
        enum Call: Sendable {
            case add(String)
            case make
        }
        @Generable struct Name: Sendable { let name: String }

        var name: String { "start" }
        var description: String { "Starts a list." }
        static let options: [ScopeOption<Call>] = [
            ScopeOption(name: "add", description: "Adds a name.", input: Name.self) { .add($0.name) },
            ScopeOption(name: "make", description: "Makes the list.", input: EmptyToolInput.self) { _ in .make },
        ]

        func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

        func run(_ input: Input, in scope: borrowing ToolScope<Call>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            var names: [String] = []
            await scope.show(.text("Started."), offering: Self.options)
            while let event = await scope.next() {
                switch consume event {
                case .turn(let turn):
                    await turn.show(
                        .text("Still a list of \(names.joined(separator: ", ")); nothing made yet."),
                        offering: Self.options)
                case .call(let call):
                    let value = call.value
                    switch value {
                    case .add(let name):
                        guard !names.contains(name) else {
                            await call.fail(ToolError.invalidArgument("name", value: name))
                            continue
                        }
                        names.append(name)
                        await call.reply(.text("So far: \(names.joined(separator: ", "))"), offering: Self.options)
                    case .make:
                        return .text("Made: \(names.joined(separator: ", "))")
                    }
                }
            }
            throw CancellationError()
        }
    }

    private func call(_ registry: inout AgentSession, _ id: String, _ name: String, adding added: String? = nil)
        async throws -> ToolExecution
    {
        let arguments = added.map { GeneratedContent(properties: ["name": $0]) } ?? GeneratedContent(properties: [:])
        return try await registry.executeWithOutputs([ToolCall(id: id, name: name, arguments: arguments)])[0]
    }

    @Test("a call works with the model in its scope, until its result; the scope then collapses to it")
    func callsWorkInTheirScope() async throws {
        var registry = AgentSession()
        registry.register(tools: [ListTool()])
        let started = try await call(&registry, "1", "start")
        #expect(started.result.output.textRepresentation == "Started.")
        #expect(registry.schemas().map(\.name) == ["add", "make", "start"])

        _ = try await call(&registry, "2", "add", adding: "Ann")
        // A call that fails fails alone: the scope goes on as it was.
        #expect(try await call(&registry, "3", "add", adding: "Ann").result.isError)
        _ = try await call(&registry, "4", "add", adding: "Bob")

        let made = try await call(&registry, "5", "make")
        #expect(made.result.output.textRepresentation == "Made: Ann, Bob")
        #expect(registry.schemas().map(\.name) == ["start"])
    }

    @Test("answering ends no scope: the next turn begins inside the ones left open")
    func scopesOutliveTurns() async throws {
        var scope = AgentSession()
        scope.offer(TurnTools(tools: [ListTool()]))
        _ = try await call(&scope, "1", "start")
        _ = try await call(&scope, "2", "add", adding: "Ann")

        // The next turn begins inside the open scope: it offers what it offers, and nothing
        // arrived, since no call was still working.
        let arrivals = await scope.begin(TurnID())
        #expect(arrivals.isEmpty)
        #expect(scope.schemas().map(\.name) == ["add", "make", "start"])
        _ = try await call(&scope, "3", "add", adding: "Bob")
        #expect(try await call(&scope, "4", "make").result.output.textRepresentation == "Made: Ann, Bob")
    }

    @Test("a call still working stays open beside other calls, until ending the agent's scope cancels it")
    func workingCallsStayOpen() async throws {
        var registry = AgentSession()
        registry.register(tools: [ListTool(), NowTool()])
        _ = try await call(&registry, "1", "start")
        _ = try await call(&registry, "2", "now")
        #expect(registry.schemas().map(\.name) == ["add", "make", "now", "start"])
        _ = try await call(&registry, "3", "add", adding: "Ann")

        await registry.end()
        #expect(registry.schemas().map(\.name) == ["now", "start"])
    }

    @Test("two calls can work side by side, each answering its own")
    func callsSideBySide() async throws {
        var registry = AgentSession()
        registry.register(tools: [ListTool(), SecondListTool()])
        _ = try await call(&registry, "1", "start")
        _ = try await call(&registry, "2", "start_second")
        _ = try await call(&registry, "3", "add", adding: "Ann")
        _ = try await call(&registry, "4", "add_second", adding: "Bob")
        #expect(try await call(&registry, "5", "make").result.output.textRepresentation == "Made: Ann")
        #expect(try await call(&registry, "6", "make_second").result.output.textRepresentation == "Made: Bob")
    }

    /// A second list, with tools of its own names, to work beside the first.
    struct SecondListTool: HailCore.Tool {
        typealias Input = EmptyToolInput
        typealias Call = ListTool.Call
        var name: String { "start_second" }
        var description: String { "Starts another list." }
        static let options: [ScopeOption<Call>] = [
            ScopeOption(name: "add_second", description: "Adds a name.", input: ListTool.Name.self) { .add($0.name) },
            ScopeOption(name: "make_second", description: "Makes the list.", input: EmptyToolInput.self) { _ in .make },
        ]

        func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

        func run(_ input: Input, in scope: borrowing ToolScope<Call>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            var names: [String] = []
            await scope.show(.text("Started."), offering: Self.options)
            while let event = await scope.next() {
                switch consume event {
                case .turn(let turn):
                    await turn.show(.text("Still a list."), offering: Self.options)
                case .call(let call):
                    let value = call.value
                    switch value {
                    case .add(let name):
                        names.append(name)
                        await call.reply(.text("So far: \(names.joined(separator: ", "))"), offering: Self.options)
                    case .make:
                        return .text("Made: \(names.joined(separator: ", "))")
                    }
                }
            }
            throw CancellationError()
        }
    }

    /// Takes the model's calls and never answers them.
    struct SilentTool: HailCore.Tool {
        typealias Input = EmptyToolInput
        var name: String { "silent" }
        var description: String { "Never answers." }

        func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

        func run(
            _ input: Input, in scope: borrowing ToolScope<ListTool.Call>, token: borrowing EffectToken<ClockEffect>
        ) async throws -> CallReturn {
            await scope.show(.text("Listening."), offering: ListTool.options)
            while let event = await scope.next() { _ = consume event }
            throw CancellationError()
        }
    }

    @Test("a call the scope doesn't answer fails, instead of waiting forever")
    func unansweredCallsFail() async throws {
        var registry = AgentSession()
        registry.register(tools: [SilentTool()])
        _ = try await call(&registry, "1", "silent")
        let unanswered = try await call(&registry, "2", "add", adding: "Ann")
        #expect(unanswered.result.isError)
        #expect(unanswered.result.output.textRepresentation.contains("no answer"))
    }

    /// Fails, with a page linking the tool to recover with.
    struct ExistsTool: HailCore.Tool {
        typealias Input = EmptyToolInput
        var name: String { "make" }
        var description: String { "Makes it." }

        func effect(for input: Input) throws -> ClockEffect { ClockEffect() }

        func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>)
            async throws -> CallReturn
        {
            throw ToolPageError(.text("It already exists.", links: [GeneratedInputTool()]))
        }
    }

    @Test("a failure is a page too: its links are offered, like a result's")
    func failuresLink() async throws {
        var registry = AgentSession()
        registry.register(tools: [ExistsTool()])
        let failed = try await call(&registry, "1", "make")
        #expect(failed.result.isError)
        #expect(failed.result.output.textRepresentation == "It already exists.")
        #expect(registry.schemas().map(\.name) == ["generated_input", "make"])
    }

    @Test("called with no model, a call's result is the first page its scope shows")
    func noModel() async throws {
        let page = try await AnyTool(ListTool()).runOutput(
            generatedContent: GeneratedContent(properties: [:]), authority: FullAuthority())
        #expect(page.result.textRepresentation == "Started.")
    }

    @Test("generated arguments are decoded without a JSONDecoder round trip")
    func generatedArgumentsExecute() async throws {
        let tool = AnyTool(GeneratedInputTool())
        let generated = GeneratedContent(properties: ["message": "hello"])
        let output = try await tool.runOutput(
            generatedContent: generated,
            authority: FullAuthority()
        )

        #expect(output.result == .text("hello"))
    }
}

extension ToolRegistryTests {
    @Generable
    struct Plan {
        @Generable
        enum Verb: String { case add, reply }
        @Generable
        struct Step {
            let action: Verb
            let value: String?
        }
        let name: String
        let start: String?
        let steps: [Step]
    }

    /// Small models send a nested argument as JSON text, and numbers where text was asked for;
    /// both are read as the schema asks. Text inside stays text.
    @Test("arguments are brought to the schema's shape")
    func argumentsAreConformed() throws {
        let plan = try Plan(
            leniently: try GeneratedContent(
                json:
                    #"{"name": "n", "start": "[]", "steps": "[{\"action\": \"add\", \"value\": 1}, {\"action\": \"reply\", \"value\": \"[]\"}]"}"#
            ))
        #expect(plan.start == "[]")
        #expect(plan.steps.map(\.value) == ["1", "[]"])
        // A list where text was asked for is read as its JSON text.
        #expect(
            try Plan(leniently: try GeneratedContent(json: #"{"name": "n", "start": [], "steps": []}"#)).start == "[]")
    }

    /// What doesn't fit is named by its path, with what it should be.
    @Test("a mismatch names its path")
    func mismatchesNameTheirPath() throws {
        func error(_ json: String) -> String {
            do {
                _ = try Plan(leniently: try GeneratedContent(json: json))
                return ""
            } catch {
                return String(describing: error)
            }
        }
        #expect(
            error(#"{"name": "n", "steps": [{"action": "add"}, {"reply": "x"}]}"#)
                == "`steps[1]` needs `action`, one of add, reply; `reply` isn't one of its parts. Its parts: action, value."
        )
        #expect(
            error(#"{"name": "n", "steps": [{"action": "filter"}]}"#)
                == "`steps[0].action` is `filter`, but it's one of add, reply.")
        #expect(error(#"{"name": "n", "steps": "add"}"#) == #"`steps` is `"add"`, but it's a list."#)
        #expect(
            error(#"{"name": "n", "steps": "[{\"action\": \"reply\", \"value\": \"a\" + b}]"}"#).hasPrefix(
                "`steps` is JSON text that doesn't read"))
    }
}

extension ToolRegistryTests {
    @Generable
    struct Outer {
        @Generable
        struct Value { let text: String }
        @Generable
        struct Other {
            @Generable
            struct Value { let count: Int }
            let value: Value
        }
        let value: Value
        let other: Other
    }

    /// A tool's schema names each definition by its last part, numbering only a clash, and its
    /// references follow.
    @Test("definitions are named short, references follow")
    func definitionsAreNamedShort() throws {
        let schema = ToolDefinition(name: "t", description: "", parameters: Outer.generationSchema).parameters
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
        let definitions = try #require(json["$defs"] as? [String: Any])
        #expect(Set(definitions.keys) == ["Outer", "Other", "Value", "Value2"])
        let text = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        #expect(!text.contains("ToolRegistryTests."))
        // Arguments still decode with the shortened schema.
        let content = try GeneratedContent(json: #"{"value": {"text": "a"}, "other": {"value": {"count": 1}}}"#)
        #expect(try Outer(content).other.value.count == 1)
    }
}
