# ``HailCore``

Hail's agent domain: identities, history and activity, model contracts, tools, and the effects
tools describe.

## Overview

`HailCore` holds the values everything else is built from, and no runtime. An agent's identity is
an ``AgentID``; what it did is its ``AgentHistory``, recorded as ``AgentEvent``s; what it's doing
now is its ``AgentActivity`` and ``AgentStatusSnapshot``.

Models are reached through ``ModelEndpoint``, by an ``AgentModel`` that names where a model runs.
A tool is a ``Tool`` whose `@Generable` input is both the schema the model sees and the value the
tool receives; it names the effect it needs, and runs only with that effect's token.

Depend on `HailCore` alone to describe agents, tools and effects without the distributed runtime.

## Topics

### Agents

- ``AgentID``
- ``Role``
- ``AgentContextID``
- ``AgentDefinition``
- ``AgentPersona``
- ``AgentSpawnConfig``
- ``InterruptedTurns``
- ``AgentWorkspace``
- ``WorkspaceID``

### History and activity

- ``AgentHistory``
- ``AgentEvent``
- ``AgentActivity``
- ``AgentStatus``
- ``AgentStatusSnapshot``
- ``AgentUsageSummary``
- ``TurnID``
- ``ModelRequestRecord``
- ``ModelRequestID``

### Models

- ``ModelEndpoint``
- ``ModelEndpointRequest``
- ``AgentModel``
- ``AgentModelProvider``
- ``ModelConfiguration``
- ``ModelCatalog``
- ``ModelUsage``
- ``ContextUsage``
- ``ModelReasoningCapabilities``
- ``ReasoningEffort``

### Tools

- ``Tool``
- ``AnyTool``
- ``AgentSession``
- ``TurnTools``
- ``ToolScope``
- ``ToolPage``
- ``ToolPages``
- ``CallReturn``
- ``ToolDefinition``
- ``FileTool``
- ``NowTool``

### Effects

- ``FileEffect``
- ``TerminalEffect``
- ``ProcessEffect``
- ``NetworkEffect``
- ``CoordinationEffect``
- ``ClockEffect``
- ``ProcessSandboxPolicy``
