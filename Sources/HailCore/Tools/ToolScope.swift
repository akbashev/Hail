import AnyLanguageModel
import ScopedEffect
import Synchronization

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - The tool's side

/// A tool call's scope, lent to the tool for as long as it runs, the way `withEffect` lends an
/// ``EffectToken``. It can't be stored, captured, or returned, so nothing about the call can live
/// outside the call: its state is the tool's locals.
///
/// A tool that has its result at once never uses it. A tool that needs more from the model shows
/// it a page, offering tools of its own, and answers the model's calls to them, one at a time,
/// until it returns its result.
public struct ToolScope<Call: Sendable>: ~Escapable, ~Copyable {
    let channel: ScopeChannel<Call>

    /// The call that opened this scope, in the turn it was made: a stable key for the call's
    /// effect, so doing it again finds it done.
    public var origin: Origin { channel.origin }

    @_lifetime(borrow channel)
    init(_ channel: borrowing ScopeChannel<Call>) {
        self.channel = copy channel
    }

    /// Shows the model where the call is, offering what it can call inside it. This answers the
    /// call that opened the scope.
    public func show(_ page: Page, offering options: [ScopeOption<Call>]) async {
        await channel.answer(.shown(page, options.map(\.schema)), options: options)
    }

    /// What happens next in the scope: the model calls a tool it offers, or comes back to it in a
    /// new turn. Nil once the model leaves it. A call taken and not answered before asking for
    /// the next fails.
    public func next() async -> ScopeEvent<Call>? {
        switch await channel.nextIncoming() {
        case .call(let value): .call(CallToken(value: value, channel: channel))
        case .turn(let turn): .turn(TurnToken(turn: turn, channel: channel))
        case nil: nil
        }
    }
}

/// What a scope's tool learns next.
public enum ScopeEvent<Call: Sendable>: ~Copyable {
    /// The model called a tool the scope offers.
    case call(CallToken<Call>)
    /// The model came back to the scope in a new turn: the tool says where things are.
    case turn(TurnToken<Call>)
}

/// What opened a scope: a tool call, in a turn.
public struct Origin: Sendable {
    public let call: ToolCall
    public let turn: TurnID

    public init(call: ToolCall, turn: TurnID) {
        self.call = call
        self.turn = turn
    }

    /// A call made directly, outside any turn: a turn of its own.
    static func direct(_ call: ToolCall) -> Origin {
        Origin(call: call, turn: TurnID())
    }
}

/// A new turn the model came back to a scope in, waiting for the scope's page. Showing it uses it
/// up; the page opens the turn, so the model sees where things are before it does anything.
public struct TurnToken<Call: Sendable>: ~Copyable {
    public let turn: TurnID
    let channel: ScopeChannel<Call>

    /// Shows the model the scope as it is now, at the start of the turn.
    public consuming func show(_ page: Page, offering options: [ScopeOption<Call>]) async {
        await channel.answer(.shown(page, options.map(\.schema)), options: options)
    }
}

/// One of the model's calls inside a scope, waiting for its answer. Answering uses it up. A call
/// the tool returns its result after is answered by that result.
///
/// Read ``value`` into a local before switching on it: answering inside a `switch call.value`
/// trips a compiler bug with noncopyable values (Swift 6.4).
public struct CallToken<Call: Sendable>: ~Copyable {
    public let value: Call
    let channel: ScopeChannel<Call>

    /// Answers this call with the scope's page now, and what it offers from now on.
    public consuming func reply(_ page: Page, offering options: [ScopeOption<Call>]) async {
        await channel.answer(.shown(page, options.map(\.schema)), options: options)
    }

    /// Answers this call with an error. Only this call fails; the scope goes on as it was.
    public consuming func fail(_ error: any Error) async {
        await channel.answer(.failed(error), options: nil)
    }
}

/// A tool a scope offers. The model calls it like any tool; its arguments become a value for the
/// scope's tool, which answers it.
public struct ScopeOption<Call: Sendable>: Sendable {
    public let schema: ToolDefinition
    let call: @Sendable (GeneratedContent) throws -> Call

    public var name: String { schema.name }

    /// An option whose arguments the tool reads itself, with a schema made for them.
    public init(_ schema: ToolDefinition, call: @escaping @Sendable (GeneratedContent) throws -> Call) {
        self.schema = schema
        self.call = call
    }

    /// An option whose arguments are a `Generable` input.
    public init<Input: Generable & Sendable>(
        name: String, description: String, input: Input.Type = Input.self,
        call: @escaping @Sendable (Input) throws -> Call
    ) {
        self.schema = ToolDefinition(name: name, description: description, parameters: Input.generationSchema)
        self.call = { try call(try Input(leniently: $0)) }
    }
}

/// Lends `body` the scope of a call, for exactly as long as it runs.
func withScope<Call: Sendable, Result>(
    _ channel: ScopeChannel<Call>,
    _ body: (borrowing ToolScope<Call>) async throws -> Result
) async rethrows -> Result {
    let scope = ToolScope(channel)
    return try await body(scope)
}

extension Tool where Call == Never {
    /// Runs it with its effect already authorized, and no model to work with: a tool that offers
    /// nothing in its scope has just its result.
    public func runOutput(input: Input, token: borrowing EffectToken<Effect>) async throws -> Page {
        let channel = ScopeChannel<Never>(origin: .direct(ToolCall(id: UUID().uuidString, name: name, arguments: input.generatedContent)))
        await channel.end()
        let scope = ToolScope(channel)
        return try await run(input, in: scope, token: token)
    }
}

// MARK: - The caller's side

/// A tool call running in its scope, held by the scope it was called from. Ending it is how the
/// call ends: with its result, or cancelled if it's left first. Dropped, it's cancelled.
struct Scope: ~Copyable, Sendable {
    /// The call that opened it, and its turn.
    let origin: Origin
    /// Its calls whose results are its pages, oldest first: the call that opened it, then the
    /// calls answered inside it.
    var pages: [String]
    /// The call still working in it; nil once the call has its result.
    let running: RunningCall?
    /// The tools the working call offers.
    var offered: [ToolDefinition]
    /// The tools its page links to: each called in a scope of its own, inside this one.
    var links: [AnyTool]
    /// The scopes opened inside it, oldest first.
    var children: [InnerScope] = []

    var tools: [AnyTool] { offered.map(AnyTool.init(offered:)) + links }

    /// Cancels it, and every scope inside it, waiting for each call to stop.
    consuming func end() async {
        for child in children.reversed() {
            if let token = child.take() { await token.end() }
        }
        if let running { await running.end() }
    }

    /// Ends it well, and every scope inside it first: each call's `next()` gives nil, and it
    /// finishes, rather than being cancelled.
    consuming func finish() async {
        for child in children.reversed() {
            if let token = child.take() { await token.finish() }
        }
        if let running { await running.finish() }
    }

    deinit { running?.task.cancel() }
}

/// A scope opened inside another, owned by it: a box, since a noncopyable value can't hold ones
/// of its own kind directly.
final class InnerScope: Sendable {
    private let token: Mutex<Scope?>

    init(_ token: consuming Scope) {
        self.token = Mutex(Optional(token))
    }

    func take() -> Scope? {
        token.withLock { $0.take() }
    }

    func read<Result>(_ body: (borrowing Scope) -> Result) -> Result? {
        token.withLock { value in
            guard let token = value.take() else { return nil }
            let result = body(token)
            value = consume token
            return result
        }
    }

    func modify<Result>(_ body: (inout Scope) -> Result) -> Result? {
        token.withLock { value in
            guard var token = value.take() else { return nil }
            let result = body(&token)
            value = consume token
            return result
        }
    }
}

/// A tool call running in its scope: the channel to it, and its task.
struct RunningCall: Sendable {
    let channel: any OpenScope
    let task: Task<Void, Never>

    /// The next answer, cancelling the call if the task waiting for it is cancelled.
    func answer() async -> ScopeAnswer {
        await withTaskCancellationHandler {
            await channel.next()
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the call, and waits for it. Cancelled first, so the call sees why its calls ended.
    func end() async {
        task.cancel()
        await channel.end()
        await task.value
    }

    /// Ends the call well: its `next()` gives nil, and it finishes, uncancelled. Waits for it.
    func finish() async {
        await channel.end()
        await task.value
    }

    /// Its result with no model to answer it: the first page it shows, or its result.
    func resultWithoutModel() async throws -> Page {
        let event = await answer()
        await end()
        switch event {
        case .shown(let page, _), .finished(let page): return page
        case .failed(let error), .ended(let error): throw error
        }
    }
}

/// Calls `tool` in a scope of its own, on a task of its own, so it can wait for the model between
/// its pages. Its effect is authorized there, so the effect's token stays with the tool.
func call<T: Tool>(_ tool: T, _ input: T.Input, authority: any Authority, origin: Origin) throws -> RunningCall {
    let effect = try tool.effect(for: input)
    let authority = tool.effective(authority)
    let channel = ScopeChannel<T.Call>(origin: origin)
    let task = Task {
        do {
            let page = try await withScope(channel) { scope in
                try await withEffect(effect, authority: authority) { token in
                    try await tool.run(input, in: scope, token: token)
                }
            }
            await channel.finish(.finished(page))
        } catch {
            await channel.finish(.ended(error))
        }
    }
    return RunningCall(channel: channel, task: task)
}

// MARK: - Between them

/// What a scope answers its caller with: to the call that opened it, a call made in it, or a new
/// turn.
enum ScopeAnswer: Sendable {
    /// A page: the scope is open, offering these tools.
    case shown(Page, [ToolDefinition])
    /// The call it answered failed; the scope is open as it was.
    case failed(any Error)
    /// The call's result: the scope has ended.
    case finished(Page)
    /// The scope ended with an error, or was cancelled.
    case ended(any Error)
}

/// The tool went on without answering a call the model made in its scope.
public struct ScopeCallUnanswered: Error, CustomStringConvertible {
    public var description: String { "The call got no answer." }
}

/// A scope's channel as its caller holds it, whatever its calls are.
protocol OpenScope: Actor {
    /// The answer to the call that opened it, or to the call just made in it.
    func next() async -> ScopeAnswer
    /// The model calls one of the tools it offers.
    func call(_ name: String, arguments: GeneratedContent) async -> ScopeAnswer
    /// The model comes back to it in a new turn: its page for the turn's start, if it shows one.
    func enter(_ turn: TurnID) async -> ScopeAnswer
    /// The model left it, or answered: its calls end.
    func end()
}

/// The two sides of a scope: the tool, answering, and its caller, waiting for answers.
actor ScopeChannel<Call: Sendable>: OpenScope {
    /// What the tool learns next: a call the model made, or a new turn.
    enum Incoming: Sendable {
        case call(Call)
        case turn(TurnID)
    }

    nonisolated let origin: Origin
    private var options: [ScopeOption<Call>] = []
    /// The caller, waiting for the answer to a call; or an answer no one waited for yet.
    private var waiting: CheckedContinuation<ScopeAnswer, Never>?
    private var unread: ScopeAnswer?
    /// The tool, waiting for the model's next call; or a call it hasn't taken yet.
    private var receiving: CheckedContinuation<Incoming?, Never>?
    private var inbox: [Incoming] = []
    /// Whether a call the tool took is still waiting for its answer.
    private var answering = false
    private var ended = false

    init(origin: Origin) {
        self.origin = origin
    }

    func answer(_ event: ScopeAnswer, options: [ScopeOption<Call>]?) {
        if let options { self.options = options }
        answering = false
        deliver(event)
    }

    /// The tool returned, or threw: that answers the call it was answering, or the one that
    /// opened it.
    func finish(_ event: ScopeAnswer) {
        answering = false
        deliver(event)
        end()
    }

    private func deliver(_ event: ScopeAnswer) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: event)
        } else {
            unread = event
        }
    }

    func next() async -> ScopeAnswer {
        if let unread {
            self.unread = nil
            return unread
        }
        return await withCheckedContinuation { waiting = $0 }
    }

    func call(_ name: String, arguments: GeneratedContent) async -> ScopeAnswer {
        guard !ended, let option = options.first(where: { $0.name == name }) else {
            return .failed(ToolError.notConfigured("\(name) is no longer offered"))
        }
        let value: Call
        do { value = try option.call(arguments) } catch { return .failed(error) }
        return await send(.call(value))
    }

    func enter(_ turn: TurnID) async -> ScopeAnswer {
        guard !ended else { return .failed(ScopeCallUnanswered()) }
        return await send(.turn(turn))
    }

    /// Hands the tool what happened, and waits for its answer.
    private func send(_ incoming: Incoming) async -> ScopeAnswer {
        answering = true
        if let receiving {
            self.receiving = nil
            receiving.resume(returning: incoming)
        } else {
            inbox.append(incoming)
        }
        return await next()
    }

    /// The tool asks what happens next. Something it took and didn't answer fails now.
    func nextIncoming() async -> Incoming? {
        if answering { answer(.failed(ScopeCallUnanswered()), options: nil) }
        if !inbox.isEmpty { return inbox.removeFirst() }
        if ended { return nil }
        return await withCheckedContinuation { receiving = $0 }
    }

    func end() {
        ended = true
        if let receiving {
            self.receiving = nil
            receiving.resume(returning: nil)
        }
    }
}
