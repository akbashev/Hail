# Hail

An umbrella module for Hail's agent domain, model integrations, distributed runtime, and scoped effects.

## Overview

Import `Hail` to use the complete runtime, or import one of its narrower products:

- `HailCore` for agent values, model contracts, effect descriptors, and tools.
- `HailModelRuntime` for model routing and AnyLanguageModel endpoints.
- `HailAgentRuntime` for the distributed event-sourced actor and reasoning runtime.
- `HailCompaction` for budget-aware context compaction and local tokenizer support.
- `ScopedEffect` for capability scopes, authority decisions, audit, and secret vocabulary.

An `Agent` is a distributed virtual actor: addressable by `AgentID`, auto-passivated, and recovered from its event journal. There is no outer polling loop — an agent handles a message, reasons, emits events, and goes idle. Turn recovery is a runtime feature: streamed turns are bracketed by journaled events, and an interrupted turn is re-issued on activation.

Models route through `ModelEndpoint` implementations: AnyLanguageModel for hosted, local, and on-device models, or a host's own endpoint. Hosts provide `ModelRouterConfiguration` (credentials, URLs, generation policy, and per-model reasoning capabilities) when composing the runtime; Hail does not read provider environment variables or choose product defaults. The journal is the durable source of truth.

Tools are answered inside the turn's model request by the agent's `AgentSession`, under the turn's authority. Every `Tool` maps its decoded input to one concrete effect descriptor, and its implementation can only run with the matching non-escapable token. The session authorizes that effect before invoking the tool; `AnyTool` preserves the concrete effect type through type erasure. Agent-facing effect domains live in `HailCore`.

## Topics

### Agents

- ``Agent``
- ``AgentID``
- ``Role``
- ``AgentContextID``
- ``AgentSpawnConfig``
- ``WorkspaceID``
- ``AgentDefinition``
- ``AgentActivity``
- ``AgentUsageSummary``
- ``AgentStatusSnapshot``
- ``ModelRequestRecord``
- ``AgentStream``
- ``AgentHistory``

### Models

- ``ModelEndpoint``
- ``AnyLanguageModelEndpoint``
- ``ModelRouter``
- ``ModelRouterConfiguration``
- ``ReasoningEffort``
- ``ReasoningEffortEncoding``
- ``ReasoningEffortSelection``
- ``ModelReasoningLevel``
- ``ModelReasoningCapabilities``
- ``ModelCatalog``
- ``AgentModel``
- ``AgentModelProvider``
- ``ModelUsage``
- ``ContextUsage``
- ``TurnID``
- ``ModelRequestID``

### Tools

- ``Tool``
- ``AgentSession``
- ``TurnTools``
- ``ToolPage``
- ``ToolScope``
- ``CallToken``
- ``FileTool``
- ``AgentTool``

### Effects

- ``FileEffect``
- ``TerminalEffect``
- ``ProcessEffect``
- ``NetworkEffect``
- ``CoordinationEffect``
- ``ClockEffect``
