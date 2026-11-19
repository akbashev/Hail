# Tools, effects and authority

How a tool says what it does, how the host decides whether it may, and how secrets stay out of the
model's reach.

## Overview

A tool's input is a `@Generable` type: the same type is the schema the model sees and the value the
tool receives. Each tool names the **effect** it needs, and runs only once the host's authority has
granted it.

### Tools

```swift
@Generable
struct SignalInput: Sendable {
    /// The frequency to listen on, in megahertz.
    let frequency: Double
}

@Tool("listen", description: "Listen on a frequency and report what is heard.")
struct ListenTool {
    func effect(for input: SignalInput) throws -> ClockEffect { ClockEffect() }

    func run(
        _ input: SignalInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>
    ) async throws -> CallReturn {
        .text("Static on \(input.frequency) MHz.")
    }
}
```

A tool's result can also say what comes next: tools the model can call next, offered beside the
result, or a ``ToolPage`` the call opened. The model starts each turn from a few tools and reaches
the rest through them, instead of seeing every tool at once. The tools a turn starts with are its
``TurnTools``.

### Effects

An effect is anything an agent does outside its own reasoning: reading or writing a file, running a
command, or making a network request. Hail represents that action as a typed value before
performing it. ``FileEffect`` can say "read this file", but the value itself touches nothing and
grants nothing.

```swift
let requestedRead = FileEffect(path: projectRoot + "/README.md", action: .read)
```

The effect domains an agent can use are ``FileEffect``, ``TerminalEffect``, ``ProcessEffect``,
``NetworkEffect``, ``CoordinationEffect`` and ``ClockEffect``.

### Authority

The model shouldn't decide which files the process can access. An `Authority` is the host's answer
to "may this described effect run?". This one allows reads only inside `projectRoot`; the tool
reads only after the decision is granted.

```swift
let authority = CompositeAuthority()
    .granting(for: FileEffect.self, decide: FileEffect.pathPolicy(scopedTo: projectRoot))
let file = AnyTool(FileTool(projectRoot: URL(fileURLWithPath: projectRoot)))
let read = try await file.runOutput(
    generatedContent: try GeneratedContent(json: #"{"action":"read","path":"README.md"}"#),
    authority: authority
)
```

A refusal says why, and can carry exactly what was refused, so whoever the call is for can act on
it: a refused tool call's result carries its refusal back. No agent has an authority of its own:
an agent acts for whoever its turn is for, so the node's one authority decides every effect each
turn makes, for them.

### Secrets as references

Passing an API key as a `String` would make it ordinary data that could end up in prompts, events,
logs or configuration. A `SecretRef` stores only a lookup, such as an environment variable's name.
The agent asks for the operation, the authority decides on the network access, and the host
resolves the reference only while the tool performs the request.

```swift
let apiKey = SecretRef.env("SEARCH_API_KEY")
let search = NetworkEffect(
    host: "api.example.com",
    operation: "GET /search",
    request: NetworkRequest(url: "https://api.example.com/search?q=signal")
)
let authority = CompositeAuthority()
    .granting(for: NetworkEffect.self, decide: NetworkEffect.hostPolicy(allowing: ["api.example.com"]))

try await withEffect(search, authority: authority) { token in
    // Resolve apiKey and perform the request with token.
}
```

The design follows Odersky and collaborators' work on tracked capabilities for safer agents,
adapted to Swift: see the `ScopedEffect` module.
