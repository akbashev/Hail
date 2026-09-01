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

### Spawn an agent

`scoutID` is the agent's stable address. A virtual distributed actor can be local, remote, idle, or recovered while callers keep using the same identity.

```swift
import DistributedCluster
import Hail
import VirtualActors

let projectRoot = "/path/to/project"
let scoutID = AgentID(role: Role("scout"), contextID: AgentContextID("mission-7"))

// The host's definition selects the provider and model.
let scoutDefinition = AgentDefinition(
    role: scoutID.role,
    behavior: .init(
        systemPrompt: "You are a careful signal scout.",
        model: "codex/gpt-5.6-sol"
    ),
    limits: .init()
)

// The host's definitionProvider returns scoutDefinition when the agent activates.
let scout: Agent = try await system.virtualActors.getActor(
    identifiedBy: VirtualActorID(rawValue: scoutID.rawValue),
    dependency: AgentSpawnConfig(
        agentID: scoutID,
        projectRootPath: projectRoot
    )
)
```

### Talk to it

`respond` sends a message instead of calling a process-local loop and waits for a typed result. Replace `ChatResponse` with your own `Codable` output type when the domain needs a stronger contract.

```swift
let reply: ChatResponse = try await scout.respond(
    "Survey the area and report anything unusual."
)
print(reply.content)
```

### Agents talking to each other

Conceptually, a different agent can call the scout from inside its own behavior:

```swift
// Hypothetical code for another distributed agent.
distributed actor Navigator {
    let brain: Agent
    let scout: Agent

    func investigate() async throws -> ChatResponse {
        let report: ChatResponse = try await scout.respond(
            "Inspect the signal and report your findings."
        )
        return try await brain.respond(
            "The scout reported: \(report.content). Decide what we should do next."
        )
    }
}
```
Navigator addresses the scout by its virtual-actor reference, then sends the response back to its `brain` agent. Either agent may be on another node or activated after being idle; the calls remain the same.

### Stream a turn

`AgentStream<ChatResponse>` exposes the typed turn lifecycle while it runs. It lets a UI or another agent observe progress without taking ownership of the agent's loop or state.

```swift
let stream = AgentStream<ChatResponse>(actorSystem: system)
let updates = Task {
    for await update in stream.updates {
        switch update {
        case .run(.event(.toolRequested(let call, _))):
            print("Scout requested:", call.name)
        case .run(.event(.responseRecorded(let response, _))):
            print("Scout replied:", response.content)
        default:
            break
        }
    }
}

try await stream.send(
    "Inspect the signal and explain how confident you are.",
    to: scout
)
updates.cancel()
```

### What is an effect?

An effect is anything an agent does outside its own reasoning: reading a file, writing a file, running a command, or making a network request. Hail represents that outside-world action as a typed value before performing it. `FileEffect` can say “read this file” or “write to this path,” but the value itself does not touch the filesystem and does not grant permission. `ScopedEffect` is the common protocol for these effect values.

```swift
let requestedRead = FileEffect(
    path: projectRoot + "/README.md",
    action: .read
)
```

### Give a tool an authority

The agent may request `requestedRead`, but the model should not decide which files the process can access. `Authority` is the host's answer to “may this described effect run?” This example allows reads only inside `projectRoot`; the tool performs the read only after that decision is granted.

```swift
import Foundation
import HailCore
import ScopedEffect

let authority = CompositeAuthority()
    .granting(
        for: FileEffect.self,
        decide: FileEffect.pathPolicy(scopedTo: projectRoot)
    )
let file = AnyTool(FileTool(projectRoot: URL(fileURLWithPath: projectRoot)))
let contents = try await file.execute(
    input: ToolArguments(json: #"{"action":"read","path":"README.md"}"#),
    authority: authority
)
print(contents)
```

### Keep secrets as references

Agents often need credentials when a tool performs an effect—for example, an HTTP tool calling an API. Passing the API key as a `String` would make it ordinary data that could be copied into prompts, events, logs, or configuration. `SecretRef` stores only a lookup such as an environment-variable name or secret-store ID. The agent requests the operation, the authority controls the network access, and infrastructure resolves the reference only when the tool performs the request.

```swift
// Configuration contains a reference, not the secret itself.
let apiKey = SecretRef.env("OPENAI_API_KEY")
let request = NetworkEffect(host: "api.example.com", operation: "GET /search")

let authority = CompositeAuthority()
    .granting(
        for: NetworkEffect.self,
        decide: NetworkEffect.hostPolicy(allowing: ["api.example.com"])
    )

// The host resolves apiKey inside the effect scope.
try await withEffect(request, authority: authority) { token in
    try await apiClient.get(
        "/search",
        credential: secretStore.resolve(apiKey),
        effectToken: token
    )
}
```

`SecretRef` provides the credential lookup; `NetworkEffect` and `Authority` provide the access boundary. The raw secret exists only inside the infrastructure that performs the request.

### Compose the host runtime

The host supplies definitions, tools, and policy as values. This keeps product decisions—automation, tools, and trust—outside the actor runtime and explicit at composition time.

```swift
let runtime = AgentRuntimePlugin(
    definitionProvider: { spawn in
        await definitions.lookup(spawn.agentID.role)
    },
    extraToolsProvider: { agentID, sourceAgentID, system in
        makeHostTools(for: agentID, calledBy: sourceAgentID, in: system)
    },
    authorityProvider: { spawn in
        CompositeAuthority.workspaceDefault(
            root: spawn.scope.path ?? spawn.projectRootPath
        )
    }
)
```

## Why this architecture

### Distributed actors

An agent is an isolated stateful actor with a typed message boundary. It does not belong to one process or machine, and Distributed Actors make remote calls explicit. The application communicates with an agent rather than managing its mailbox or lifecycle directly.

### Durable entities

Virtual Actors give agents durable logical identity: they activate an entity when a message arrives and passivate it when idle. Event Sourcing records meaningful transitions—messages, turn boundaries, model sessions, tool activity, and responses—so a new actor instance can replay the journal and continue after failure. The journal is the source of truth; a provider's warm session is only an optimization.

### Scoped effects

An LLM can propose an action, but the host must decide what that action may touch. `ScopedEffect` represents file, process, and network operations as typed values. An `Authority` decides whether a concrete effect is allowed, and `withEffect` creates a non-escapable `EffectToken` only inside the granted scope. Authorities can be composed for workers, reviewers, trusted hosts, or untrusted turns.

This design is inspired by Martin Odersky and collaborators' work on [tracked capabilities for safer agents](https://martinodersky.substack.com/p/tracked-capabilities-for-safer-agents), adapted to Swift's current runtime and concurrency capabilities.

## Bring your own agents and models

Hail is agnostic about roles, prompts, workflows, tools, persistence layout, and UI. The host supplies definitions, context, tools, and policy as explicit values.

Models are equally open. A provider implements `ModelEndpoint` and can be hosted, local, self-hosted, or custom. Hail includes Kimi Code over ACP, Claude Code over its stream-JSON CLI, Codex over its native App Server protocol, and API-backed endpoints, but no provider is privileged by the architecture. Session-owning endpoints may keep warm conversations; stateless endpoints receive the assembled transcript. In both cases, the event journal remains the recovery authority.

### Compact context for stateless endpoints

Session-owning harnesses (Kimi, Claude, Codex) manage context server-side. Stateless endpoints (Ollama, plain chat APIs) have no such memory, so the runtime offers compaction at turn start through the `ContextCompactor` seam. The reference implementation lives in the optional `Packages/HailCompaction` library:

```swift
import HailCompaction

let runtime = AgentRuntimePlugin(
    // ... providers as above ...
    contextCompactor: SlidingWindowCompactor(
        budget: ContextWindowBudget(overrides: [("llama3.2", 131_072)])
    )
)
```

When the assembled context crosses a fraction of the model's window, the oldest messages are folded into a rolling summary journaled as one `conversationCompacted` event — replay never re-runs the summarizer, and snapshotting checkpoints the compacted state. Note Ollama applies `num_ctx = 4096` per request unless configured, so the budget defaults to that; pass overrides for windows you actually raised.

## Package layout

Depend only on the layer you need:
| Product | Purpose |
| --- | --- |
| `ScopedEffect` | Capability scopes, authority decisions, auditing, and secret vocabulary |
| `HailCore` | Agent domain values, model contracts, tools, and effect descriptors |
| `HailModelRuntime` | Model routing plus Kimi, Claude, Codex, and API endpoint implementations |
| `HailAgentRuntime` | Distributed, virtual, event-sourced agents and the reasoning runtime |
| `Hail` | Umbrella product that re-exports the complete stack |
## Requirements

- Swift 6.4 package tools
- macOS 26 for local CLI model harnesses

## Current implementation

The current implementation is built on [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) for model abstractions and [swift-acp](https://github.com/wiedymi/swift-acp) for Agent Client Protocol integrations. These are implementation foundations and may change as Hail evolves; model providers remain replaceable.

## License

Hail is licensed under the Apache License 2.0. See [LICENSE.txt](LICENSE.txt)
and [NOTICE.txt](NOTICE.txt).

Run the suite with:
```sh
swift test
```
