# Hail
**Hail an agent. It answers from wherever it lives.**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hail-pic-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/images/hail-pic-light.png">
  <img width="640" alt="Hail agents reaching across space" src="docs/images/hail-pic-light.png">
</picture>

Hail is a Swift runtime for durable, distributed LLM agents. The name comes from hailing a ship—or a spacecraft—and inviting a reply. Agents have stable identities, can communicate across a cluster, and can recover without changing where they are addressed.

LLMs are tools, not the foundation of your product. Hail is built on open-source Swift infrastructure and keeps providers replaceable: use a hosted API, a local or self-hosted model, or add your own integration. The goal is to give small teams and individual developers the freedom to build agent products without depending on one platform vendor.

Hail uses the reactive model familiar from actors: an isolated agent owns its state, receives a message, reacts, emits durable events, and becomes idle. There is no outer `while true` loop for the host to keep alive. Whether the resulting product is fully automated or human-controlled is an application decision.

## A small example

### Reach an agent

`scoutID` is the agent's stable address. A virtual distributed actor can be local, remote, idle, or recovered while callers keep using the same identity.

```swift
import DistributedCluster
import Hail

let scoutID = AgentID(role: Role("scout"), contextID: AgentContextID("mission-7"))
let scout = try await system.agent(scoutID)
```

The identity is all a caller passes. How the agent is built—its definition, model, tools, workspace and authority—is the host's policy over that identity (see [Compose the host runtime](#compose-the-host-runtime)), so every caller reaches the same agent.

### Talk to it

`respond` gives the agent its input and waits for the reply. The reply is a `@Generable` type of your own, generated as structured output:

```swift
@Generable
struct ChatReply: Codable, Sendable {
    let content: String
}

extension ChatReply.PartiallyGenerated: Codable {}

let reply: ChatReply = try await scout.respond("Survey the area and report anything unusual.")
print(reply.content)
```

The input can be any type that says what it reads as to the model (`ConvertibleToGeneratedContent`); a `String` is one.

### Agents talking to each other

An agent is a distributed actor, so anything that holds one can ask it, including another agent's code:

```swift
struct Navigator {
    let brain: Agent
    let scout: Agent

    func investigate() async throws -> ChatReply {
        let report: ChatReply = try await scout.respond("Inspect the signal and report your findings.")
        return try await brain.respond("The scout reported: \(report.content). Decide what we should do next.")
    }
}
```

Either agent may be on another node or activated after being idle; the calls remain the same.

### Watch a turn

`AgentStream` shows the turn you started while it runs, typed: the reply so far as `ChatReply.PartiallyGenerated`, the tools it calls, and the reply.

```swift
let stream = AgentStream<ChatReply>(actorSystem: system)
let updates = Task {
    for await update in stream.updates {
        switch update {
        case .toolRequested(let call, _):
            print("Scout called:", call.name)
        case .responseRecorded(let reply, _):
            print("Scout replied:", reply.content)
        default:
            break
        }
    }
}
try await stream.send("Inspect the signal and explain how confident you are.", to: scout)
stream.finish()
await updates.value
```

Anyone can also follow an agent, whoever started its turns. Its activity carries the reply so far as content, which a follower that knows the reply's type reads as its partial:

```swift
for await activity in scout {
    if case .turn(.progress(.partial(let content)), _) = activity {
        let soFar = try ChatReply.PartiallyGenerated(content)
        print(soFar.content ?? "")
    }
}
```

## Turns and history

Each input opens one **turn**, and the turn closes with the agent's reply. Inside it, the model may call tools: the agent answers those calls within the same model request, the way Apple's Foundation Models runs tools inside `respond`, so a turn is never stopped and restarted to deliver results.

The agent's history is its turns in order: each input, the tool calls and their results, and the reply. Turns run one at a time, and at most one is open—the last. A turn left open by a crash is resumed when the agent activates again, from what the journal already holds.

When something limits a turn, the model is told in plain words, and the notice is journaled with the turn:

- its answer ran out while it was thinking, after its tools answered;
- the turn made all the tool calls a turn may make (`maxToolRounds`).

## Tools

A tool's input is a `@Generable` type: the same type is the schema the model sees and the value the tool receives. Each tool names the effect it needs (see below), and runs only once the host's authority has granted it.

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

A tool's result can also say what comes next: tools the model can call next, offered beside the result, or a page of tools the call opened. The model starts each turn from a few tools and reaches the rest through them, instead of seeing every tool at once.

## Effects and authority

### What is an effect?

An effect is anything an agent does outside its own reasoning: reading a file, writing a file, running a command, or making a network request. Hail represents that outside-world action as a typed value before performing it. `FileEffect` can say "read this file" or "write to this path," but the value itself does not touch the filesystem and does not grant permission. `ScopedEffect` is the common protocol for these effect values.

```swift
let requestedRead = FileEffect(path: projectRoot + "/README.md", action: .read)
```

### Give a tool an authority

The agent may request `requestedRead`, but the model should not decide which files the process can access. `Authority` is the host's answer to "may this described effect run?" This example allows reads only inside `projectRoot`; the tool performs the read only after that decision is granted.

```swift
import Foundation
import HailCore
import ScopedEffect

let authority = CompositeAuthority()
    .granting(for: FileEffect.self, decide: FileEffect.pathPolicy(scopedTo: projectRoot))
let file = AnyTool(FileTool(projectRoot: URL(fileURLWithPath: projectRoot)))
let read = try await file.runOutput(
    generatedContent: try GeneratedContent(json: #"{"action":"read","path":"README.md"}"#),
    authority: authority
)
print(read.result.textRepresentation)
```

An authority that can't decide from what it holds, such as one that leaves a request to a person, answers `.needs`, and its `ask(about:)` waits for the answer before the effect runs. A composite effect isn't asked itself: each of its children that needs asking is asked when it runs.

### Keep secrets as references

Agents often need credentials when a tool performs an effect—for example, an HTTP tool calling an API. Passing the API key as a `String` would make it ordinary data that could be copied into prompts, events, logs, or configuration. `SecretRef` stores only a lookup such as an environment-variable name or secret-store ID. The agent requests the operation, the authority controls the network access, and infrastructure resolves the reference only when the tool performs the request.

```swift
// Configuration contains a reference, not the secret itself.
let apiKey = SecretRef.env("SEARCH_API_KEY")
let search = NetworkEffect(
    host: "api.example.com",
    operation: "GET /search",
    request: NetworkRequest(url: "https://api.example.com/search?q=signal")
)
let authority = CompositeAuthority()
    .granting(for: NetworkEffect.self, decide: NetworkEffect.hostPolicy(allowing: ["api.example.com"]))

// The host resolves apiKey inside the effect scope.
try await withEffect(search, authority: authority) { token in
    // resolve apiKey and perform the request with token
}
```

`SecretRef` provides the credential lookup; `NetworkEffect` and `Authority` provide the access boundary. The raw secret exists only inside the infrastructure that performs the request.

## Compose the host runtime

The host supplies definitions, tools, models, and policy as values. This keeps product decisions—automation, tools, and trust—outside the actor runtime and explicit at composition time.

```swift
let runtime = try AgentRuntimePlugin(
    maxToolRounds: 25,
    routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
    turnToolsProvider: { _, _ in
        TurnTools(tools: [NowTool()])
    },
    // Every agent's workspace is a directory under `workspaces`.
    authority: { _ in CompositeAuthority.workspaceDefault(root: workspaces) },
    workspaceProvider: { spawn in
        // Map the logical id to a directory you control; never splice the raw id into a path.
        AgentWorkspace(rootPath: directory(spawn.workspaceID))
    },
    definitionProvider: { spawn in
        definitions[spawn.agentID.role]
    },
    modelSelectionProvider: { _ in
        ModelConfiguration(model: try AgentModel("ollama/qwen3:8b"))
    },
    contextCompactor: SlidingWindowCompactor()
)
```

No agent has an authority of its own. An agent acts for whoever its turn is for, so the node's one `authority` decides every effect each turn makes, for them, by what the host knows of the call.

A definition is the agent's role and instructions:

```swift
let scout = AgentDefinition(
    role: Role("scout"),
    behavior: .init(systemPrompt: "You are a careful signal scout.")
)
```

## Why this architecture

### Distributed actors

An agent is an isolated stateful actor with a typed message boundary. It does not belong to one process or machine, and Distributed Actors make remote calls explicit. The application communicates with an agent rather than managing its mailbox or lifecycle directly.

### Durable entities

Virtual Actors give agents durable logical identity: they activate an entity when a message arrives and passivate it when idle. Event Sourcing records meaningful transitions—inputs, turn boundaries, tool calls and results, model requests, and replies—so a new actor instance can replay the journal and continue after failure. The journal is the source of truth.

### Scoped effects

An LLM can propose an action, but the host must decide what that action may touch. `ScopedEffect` represents file, process, and network operations as typed values. An `Authority` decides whether a concrete effect is allowed, and `withEffect` creates a non-escapable `EffectToken` only inside the granted scope. Authorities can be composed for workers, reviewers, trusted hosts, or agents that take untrusted input.

This design is inspired by Martin Odersky and collaborators' work on [tracked capabilities for safer agents](https://martinodersky.substack.com/p/tracked-capabilities-for-safer-agents), adapted to Swift's current runtime and concurrency capabilities.

## Bring your own agents and models

Hail is agnostic about roles, prompts, workflows, tools, persistence layout, and UI. The host supplies definitions, context, tools, and policy as explicit values.

Models come through [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel): hosted APIs (OpenAI and OpenAI-compatible servers, Anthropic, Gemini), local and self-hosted models (Ollama, MLX, llama.cpp, Core ML), and Apple's Foundation Models. A host can add its own provider by implementing `ModelEndpoint`, returned from the runtime's `modelEndpointProvider`.

Hail reads no provider settings from the environment. Keys, base URLs, and context windows are the host's, given in `ModelRouterConfiguration`:

```swift
let router = try ModelRouterConfiguration(
    temperature: 0.7,
    baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
    modelContextWindows: [try AgentModel("ollama/qwen3:8b"): 32_768]
)
```

### When a provider fails

Each provider says in its own way why a request failed; Hail reads it where the endpoint is made, and acts on what it means:

- **Too long for the model's context:** the history is compacted and the request asked again.
- **Busy or rate-limited:** the request waits as the provider's `Retry-After` asks, within a limit, and is asked again.
- **Never reached the model:** it is sent again as it was.

Only a request that produced nothing is asked again. Once the model has called tools, those tools have run, and asking again would run them twice.

### Compact context

Models keep no memory between requests, so the runtime offers compaction before every model request through the `ContextCompactor` seam. The reference implementation is `SlidingWindowCompactor` in the `HailCompaction` product: when the context passes a share of the model's window, earlier turns are folded into a summary, journaled once, so replay never runs the summarizer again. The turn being answered keeps its input. For exact local counts, `TokenCounter` in `HailCompaction` gives the compactor a model's own tokenizer.

Model requests also emit durable start, completion, and failure records with a `TurnID`, `ModelRequestID`, duration, and reported usage. Read the live `AgentStatusSnapshot` and `AgentActivity` for current work.

## Package layout

Depend only on the layer you need:

| Product | Purpose |
| --- | --- |
| `ScopedEffect` | Capability scopes, authority decisions, auditing, and secret vocabulary |
| `HailCore` | Agent domain values, model contracts, tools, and effect descriptors |
| `HailModelRuntime` | Model routing and AnyLanguageModel endpoints |
| `HailCompaction` | Context compaction and Hugging Face tokenizer integration |
| `HailAgentRuntime` | Distributed, virtual, event-sourced agents and the reasoning runtime |
| `Hail` | Umbrella product that re-exports the complete stack |

## Requirements

- Swift 6.4 package tools
- macOS 26

## License

Hail is licensed under the Apache License 2.0. See [LICENSE.txt](LICENSE.txt)
and [NOTICE.txt](NOTICE.txt).

Run the suite with:

```sh
swift test
```
