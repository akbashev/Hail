import AnyLanguageModel
import ScopedEffect

public struct ToolExecution: Sendable {
    public let result: ToolResult
    /// The calls this turn whose results this one replaces: earlier pages of the same scope.
    public let superseded: [String]

    public init(result: ToolResult, superseded: [String] = []) {
        self.result = result
        self.superseded = superseded
    }
}

/// The host's tools for one turn: the turn scope's.
public struct TurnTools: Sendable {
    public var tools: [any Tool]

    public init(tools: [any Tool] = []) {
        self.tools = tools
    }
}

/// The agent's scope: the root of the tree of scopes its tool calls run in, across its turns.
/// Every call runs in a scope of its own, under the scope whose tool it called; the root offers
/// the host's tools.
///
/// Scopes sit side by side, like tabs: opening one leaves the others as they are. A call still
/// working stays open while the model does other things, until it has its result. A finished
/// call's scope shows what its result links to. A call that worked with the model collapses to
/// its result. Answering ends none of them: a turn is a span of time in the
/// tree, and the next turn begins where the last one left off.
public struct AgentScope: ~Copyable, Sendable {
    private var tools: [String: AnyTool] = [:]
    /// The scopes opened from the root, oldest first.
    private var children: [InnerScope] = []
    /// The turn the model is in: the turn each call it makes is opened in.
    private var turn = TurnID()

    /// The authority effect-tools are checked against at dispatch. Defaults
    /// to ``FullAuthority`` (everything open); narrower authorities are
    /// derived per agent/lane, per turn, by the runtime plugin's provider.
    public var authority: any Authority

    public init(authority: any Authority = FullAuthority()) {
        self.authority = authority
    }

    /// The root's tools for this turn, in place of the last turn's: the host's tools can change
    /// between turns.
    public mutating func offer(_ tools: [any Tool]) {
        self.tools = [:]
        register(tools: tools)
    }

    /// Begins a turn where the last one left off: each call still working hears it, and shows its
    /// page, which opens the turn, so the model sees where things are before it does anything. A
    /// call may instead finish then, its work done: its result opens the turn in its place.
    public mutating func begin(_ turn: TurnID) async -> [Page] {
        self.turn = turn
        var pages: [Page] = []
        for entry in entries {
            guard let running = entry.scope.read({ $0.running }) ?? nil else { continue }
            switch await running.channel.enter(turn) {
            case .shown(let page, let offered):
                let links = page.links.map { AnyTool($0) }
                entry.scope.modify { (token: inout Scope) in
                    token.offered = offered
                    token.links = links
                }
                pages.append(Page(Self.output(page.output, offering: offered.map(\.name) + links.map(\.name))))
            case .finished(let page):
                // Its result opens the turn, and what it links to is offered where the call was.
                let origin = entry.scope.read { $0.origin }
                await remove(entry.scope, from: entry.parent)
                let links = page.links.map { AnyTool($0) }
                if let origin, !links.isEmpty {
                    await open(Scope(origin: origin, pages: [], running: nil, offered: [], links: links), under: entry.parent)
                }
                pages.append(Page(Self.output(page.output, offering: links.map(\.name))))
            case .ended:
                await remove(entry.scope, from: entry.parent)
            case .failed:
                continue
            }
        }
        return pages
    }

    /// Registers every tool through the same authority-aware erased witness.
    public mutating func register<T: Tool>(_ tool: T) {
        tools[tool.name] = AnyTool(tool)
    }

    public mutating func register(tools: [any Tool]) {
        for tool in tools {
            self.tools[tool.name] = AnyTool(tool)
        }
    }

    /// Ends every scope still open well, as a turn that ended normally does: each call finishes
    /// with what it has. Only the root is left.
    public mutating func finish() async {
        let open = children
        children = []
        for scope in open.reversed() {
            if let token = scope.take() { await token.finish() }
        }
    }

    /// Cancels every scope still open, as a turn that failed or was cancelled does: their calls
    /// stop, and are waited for. Only the root is left.
    public mutating func end() async {
        let open = children
        children = []
        for scope in open.reversed() {
            if let token = scope.take() { await token.end() }
        }
    }

    /// The scope a call opens under: the root, or an open scope.
    private enum Parent {
        case root
        case scope(InnerScope)
    }

    /// Every open scope with the scope it's under, in the order the model sees their tools: the
    /// newest first, and inside each, its own children before it.
    private var entries: [(scope: InnerScope, parent: Parent)] {
        func walk(_ scopes: [InnerScope], under parent: Parent) -> [(scope: InnerScope, parent: Parent)] {
            scopes.reversed().flatMap { scope in
                walk(scope.read { $0.children } ?? [], under: .scope(scope)) + [(scope, parent)]
            }
        }
        return walk(children, under: .root)
    }

    /// The tools the model can call now: every open scope's, the newest and innermost first, then
    /// the root's. A name offered earlier in that order hides the same name later.
    public func allTools() -> [AnyTool] {
        var seen: Set<String> = []
        let open = entries.flatMap { $0.scope.read { $0.tools } ?? [] }
        let root = tools.values.sorted { $0.name < $1.name }
        return (open + root).filter { seen.insert($0.name).inserted }
    }

    public func tool(named name: String) -> AnyTool? {
        allTools().first { $0.name == name }
    }

    public func schemas(forTools toolNames: [String]? = nil) -> [ToolDefinition] {
        let all = allTools()
        guard let toolNames else { return all.map(\.schema) }
        let allowed = Set(toolNames)
        return all.filter { allowed.contains($0.name) }.map(\.schema)
    }

    /// There's no tool `name`: the tools there are, with what each does, so the model can pick.
    private func unknown(_ name: String) -> String {
        "There's no tool `\(name)`. The tools are:\n"
            + allTools().map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    public mutating func execute(_ toolCalls: [ToolCall]) async throws(AgentRuntimeError) -> [ToolResult] {
        try await executeWithOutputs(toolCalls).map(\.result)
    }

    public mutating func executeWithOutputs(
        _ toolCalls: [ToolCall]
    ) async throws(AgentRuntimeError) -> [ToolExecution] {
        var executions: [ToolExecution] = []
        for call in toolCalls {
            executions.append(try await execute(call))
        }
        return executions
    }

    private func children(of parent: Parent) -> [InnerScope] {
        switch parent {
        case .root: children
        case .scope(let scope): scope.read { $0.children } ?? []
        }
    }

    private mutating func setChildren(_ scopes: [InnerScope], of parent: Parent) {
        switch parent {
        case .root: children = scopes
        case .scope(let scope): scope.modify { (token: inout Scope) in token.children = scopes }
        }
    }

    /// Opens `token` under `parent`, beside the scopes already there: like tabs, opening one
    /// leaves the others as they are.
    private mutating func open(_ token: consuming Scope?, under parent: Parent) async {
        switch consume token {
        case .some(let token): setChildren(children(of: parent) + [InnerScope(token)], of: parent)
        case .none: break
        }
    }

    /// Removes `scope` from under `parent`, ending it.
    private mutating func remove(_ scope: InnerScope, from parent: Parent) async {
        setChildren(children(of: parent).filter { $0 !== scope }, of: parent)
        if let token = scope.take() { await token.end() }
    }

    /// Runs one call in the scope that offers its tool.
    private mutating func execute(_ call: ToolCall) async throws(AgentRuntimeError) -> ToolExecution {
        guard let owner = entries.first(where: { $0.scope.read { $0.tools.contains { $0.name == call.name } } ?? false }) else {
            guard let tool = tools[call.name] else {
                return ToolExecution(result: result(call, .text("Error: " + unknown(call.name)), offering: [], failed: .rejected))
            }
            return try await start(call, tool, under: .root)
        }
        let running = owner.scope.read { token -> RunningCall? in
            token.offered.contains { $0.name == call.name } ? token.running : nil
        } ?? nil
        if let running {
            let event = await running.channel.call(call.name, arguments: call.arguments)
            return try await answer(call, by: event, in: owner.scope, under: owner.parent)
        }
        let link = owner.scope.read { $0.links.first { $0.name == call.name } } ?? nil
        return try await start(call, link!, under: .scope(owner.scope))
    }

    /// A call of a tool, in a scope of its own under `parent`. It stays open while the call works
    /// with the model, or while the model uses what its result links to.
    private mutating func start(_ call: ToolCall, _ tool: AnyTool, under parent: Parent) async throws(AgentRuntimeError) -> ToolExecution {
        let origin = Origin(call: call, turn: turn)
        let running: RunningCall
        do {
            running = try tool.call(generatedContent: call.arguments, authority: authority, origin: origin)
        } catch {
            return try await failed(call, error, under: parent)
        }
        switch await running.answer() {
        case .shown(let page, let offered):
            let links = page.links.map { AnyTool($0) }
            await open(Scope(origin: origin, pages: [call.id], running: running, offered: offered, links: links), under: parent)
            return ToolExecution(result: result(call, page.output, offering: offered.map(\.name) + links.map(\.name)))
        case .finished(let page):
            await running.end()
            return await finished(call, page, replacing: [], under: parent)
        case .failed(let error), .ended(let error):
            await running.end()
            return try await failed(call, error, under: parent)
        }
    }

    /// A call the working scope `scope`, under `parent`, answered.
    private mutating func answer(
        _ call: ToolCall, by event: ScopeAnswer, in scope: InnerScope, under parent: Parent
    ) async throws(AgentRuntimeError) -> ToolExecution {
        switch event {
        case .shown(let page, let offered):
            // The scope's newer page replaces its earlier ones.
            let links = page.links.map { AnyTool($0) }
            let earlier = scope.modify { (token: inout Scope) -> [String] in
                let earlier = token.pages
                token.pages.append(call.id)
                token.offered = offered
                token.links = links
                return earlier
            } ?? []
            return ToolExecution(
                result: result(call, page.output, offering: offered.map(\.name) + links.map(\.name)), superseded: earlier)
        case .failed(let error):
            // The scope goes on as it was; the failure's own page opens inside it.
            return try await failed(call, error, under: .scope(scope))
        case .finished(let page):
            let pages = scope.read { $0.pages } ?? []
            await remove(scope, from: parent)
            return await finished(call, page, replacing: pages, under: parent)
        case .ended(let error):
            await remove(scope, from: parent)
            return try await failed(call, error, under: parent)
        }
    }

    /// A call's result, under `parent`: what it links to is offered in a scope of its own, and the
    /// pages of the scope it worked in are replaced by it.
    private mutating func finished(_ call: ToolCall, _ page: Page, replacing pages: [String], under parent: Parent) async -> ToolExecution {
        let links = page.links.map { AnyTool($0) }
        let token: Scope? =
            links.isEmpty
            ? nil : Scope(origin: Origin(call: call, turn: turn), pages: [call.id], running: nil, offered: [], links: links)
        await open(token, under: parent)
        return ToolExecution(result: result(call, page.output, offering: links.map(\.name)), superseded: pages)
    }

    /// A failed call, under `parent`: its page, whose links are offered in a scope of its own,
    /// like any result's.
    private mutating func failed(_ call: ToolCall, _ error: any Error, under parent: Parent) async throws(AgentRuntimeError) -> ToolExecution {
        let failure = try AnyTool.failure(error, toolName: call.name)
        let links = failure.page.links.map { AnyTool($0) }
        let token: Scope? =
            links.isEmpty
            ? nil : Scope(origin: Origin(call: call, turn: turn), pages: [call.id], running: nil, offered: [], links: links)
        await open(token, under: parent)
        return ToolExecution(result: result(call, failure.page.output, offering: links.map(\.name), failed: failure.kind))
    }

    private func result(_ call: ToolCall, _ output: ToolOutput, offering names: [String], failed kind: ToolFailureKind? = nil) -> ToolResult {
        ToolResult(toolCallID: call.id, name: call.name, output: Self.output(output, offering: names), failureKind: kind)
    }

    /// The output as the model reads it: with the tools it offers named at the end.
    private static func output(_ output: ToolOutput, offering names: [String]) -> ToolOutput {
        guard !names.isEmpty, case .text(let text) = output else { return output }
        return .text(text + "\n\nNow you can use: " + names.joined(separator: ", "))
    }
}

/// What one tool call gives the model: the tool's page, or the error it reads when the call
/// failed, so the model can recover instead of the turn ending.
public enum ToolOutcome: Sendable {
    /// The tool's page: what the model reads, and what it can call next.
    case succeeded(Page)
    /// A failed call: still a page, whose links say how to recover. The kind says why it failed.
    case failed(Page, ToolFailureKind)

    /// What the model reads.
    public var output: ToolOutput {
        switch self {
        case .succeeded(let page), .failed(let page, _): page.output
        }
    }
}

/// A tool's failure with a page of its own: what went wrong, and the tools to recover with, such
/// as the object that already exists.
public struct PageError: Error, Sendable {
    public let page: Page
    public let kind: ToolFailureKind

    public init(_ page: Page, kind: ToolFailureKind = .failed) {
        self.page = page
        self.kind = kind
    }
}

extension AnyTool {
    /// Runs the tool, turning its failures into an error the model reads.
    /// Only cancellation escapes.
    public func outcome(
        generatedContent arguments: GeneratedContent,
        authority: any Authority
    ) async throws(AgentRuntimeError) -> ToolOutcome {
        do {
            let page = try await runOutput(generatedContent: arguments, authority: authority)
            return .succeeded(page)
        } catch {
            let failure = try Self.failure(error, toolName: name)
            return .failed(failure.page, failure.kind)
        }
    }

    /// A tool's error as the model reads it. Only cancellation escapes.
    static func failure(_ error: any Error, toolName name: String) throws(AgentRuntimeError) -> (page: Page, kind: ToolFailureKind) {
        switch error {
        case let error as PageError:
            return (error.page, error.kind)
        case let denial as EffectDenied:
            return (.text("Error: \(denial)"), .rejected)
        case let error as ToolError:
            return (.text(toolErrorMessage(error, toolName: name)), failureKind(for: error))
        case let mismatch as ArgumentMismatch:
            return (.text("Error: tool \(name) received invalid arguments: \(mismatch)"), .invalidArguments)
        case let error as DecodingError:
            return (.text("Error: tool \(name) received invalid arguments: \(decodingMessage(error))"), .invalidArguments)
        case is CancellationError:
            throw AgentRuntimeError.cancelled
        default:
            return (.text("Error: \(error)"), .failed)
        }
    }

    private static func toolErrorMessage(_ error: ToolError, toolName: String) -> String {
        switch error {
        case .unauthorized(let reason):
            return "Error: unauthorized: \(reason)"
        case .missingArgument(let key):
            return "Error: tool \(toolName) missing required argument: \(key)"
        case .invalidArgument(let key, let value):
            return "Error: tool \(toolName) invalid argument \(key): \(value)"
        case .notConfigured(let reason):
            return "Error: tool \(toolName) is not configured: \(reason)"
        }
    }

    private static func failureKind(for error: ToolError) -> ToolFailureKind {
        switch error {
        case .missingArgument, .invalidArgument:
            return .invalidArguments
        case .unauthorized:
            return .rejected
        case .notConfigured:
            return .unavailable
        }
    }

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "at \(codingPath(context.codingPath)): missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            return
                "at \(codingPath(context.codingPath)): expected \(String(describing: type)); \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return
                "at \(codingPath(context.codingPath)): expected \(String(describing: type)); \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "at \(codingPath(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let joined = path.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
    }
}
