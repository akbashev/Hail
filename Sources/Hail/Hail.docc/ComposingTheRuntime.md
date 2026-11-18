# Composing the host runtime

What the host gives the runtime: definitions, tools, models, workspaces and policy, as values.

## Overview

Product decisions (automation, tools and trust) stay outside the actor runtime and explicit at
composition time. The host installs one runtime plugin on its cluster node:

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
    definitionProvider: { spawn, _ in
        definitions[spawn.agentID.role]
    },
    modelSelectionProvider: { _, _ in
        ModelConfiguration(model: try AgentModel("ollama/qwen3:8b"))
    },
    contextCompactor: SlidingWindowCompactor()
)
```

### Definitions

An ``AgentDefinition`` is an agent's role and instructions:

```swift
let scout = AgentDefinition(
    role: Role("scout"),
    behavior: .init(systemPrompt: "You are a careful signal scout.")
)
```

### Identity and context

An ``AgentID`` is a ``Role`` and an ``AgentContextID``. The role says which kind of agent it is;
the context which instance: a conversation, a mission, or the role's single main instance. The
host's providers receive the identity and decide everything else from it, so the same identity
always gets the same agent, wherever it's activated.

### Why actors

An agent is an isolated, stateful actor with a typed message boundary. It doesn't belong to one
process or machine, and distributed actors make remote calls explicit. Virtual actors give agents
durable logical identity: an agent is activated when a message arrives and passivated when idle.
There's no outer loop for the host to keep alive: an agent receives a message, reacts, records what
happened, and goes idle.
