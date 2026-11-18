# Getting started

Reach an agent by its identity, give it input, and read its typed reply.

## Overview

An agent is a distributed virtual actor. Its ``AgentID`` is its stable address: the agent can be
local, remote, idle, or recovered from its journal, and callers keep using the same identity.

### Reach an agent

```swift
import DistributedCluster
import Hail

let scoutID = AgentID(role: Role("scout"), contextID: AgentContextID("mission-7"))
let scout = try await system.agent(scoutID)
```

The identity is all a caller passes. How the agent is built, its definition, model, tools,
workspace and authority, is the host's policy over that identity, so every caller reaches the same
agent. See <doc:ComposingTheRuntime>.

### Talk to it

`respond` gives the agent its input and waits for the reply. The reply is a `@Generable` type of
your own, generated as structured output:

```swift
@Generable
struct ChatReply: Codable, Sendable {
    let content: String
}

extension ChatReply.PartiallyGenerated: Codable {}

let reply: ChatReply = try await scout.respond("Survey the area and report anything unusual.")
print(reply.content)
```

The input can be any type that says what it reads as to the model
(`ConvertibleToGeneratedContent`); a `String` is one.

### Agents talking to each other

An agent is a distributed actor, so anything that holds one can ask it, including another agent's
code. Either agent may be on another node or activated after being idle; the calls stay the same.

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

### Watch a turn

``AgentStream`` shows the turn you started while it runs, typed: the reply so far as
`ChatReply.PartiallyGenerated`, the tools it calls, and the reply. Each update names its turn.

```swift
let stream = AgentStream<ChatReply>(actorSystem: system)
let updates = Task {
    for await update in stream.updates {
        switch update.event {
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

Anyone can also follow an agent, whoever started its turns. Its ``AgentActivity`` carries the reply
so far as content, which a follower that knows the reply's type reads as its partial:

```swift
for await activity in scout {
    if case .turn(.progress(.partial(let content)), _) = activity {
        let soFar = try ChatReply.PartiallyGenerated(content)
        print(soFar.content ?? "")
    }
}
```
