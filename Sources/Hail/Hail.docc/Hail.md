# Hail

An umbrella module for Hail's agent domain, model integrations, distributed runtime, and scoped effects.

## Overview

Import `Hail` to use the complete runtime, or import one of its narrower products:

- `HailCore` for agent values, model contracts, effect descriptors, and tools.
- `HailModelRuntime` for model routing and concrete Kimi, Claude, Codex, and API endpoints.
- `HailAgentRuntime` for the distributed event-sourced actor and reasoning runtime.
- `ScopedEffect` for capability scopes, authority decisions, audit, and secret vocabulary.

An `Agent` is a distributed virtual actor: addressable by `AgentID`, auto-passivated, and recovered from its event journal. There is no outer polling loop — an agent handles a message, reasons, emits events, and goes idle. Turn recovery is a runtime feature: streamed turns are bracketed by journaled events, and an interrupted turn is re-issued on activation.

Models route through `ModelEndpoint` implementations — session-owning harnesses (`KimiCodeEndpoint` over ACP, `ClaudeCliEndpoint`, and `CodexAppServerEndpoint`) keep the live conversation in the harness session and receive only the per-turn `TurnDelta`, while stateless API providers always receive the assembled transcript. The journal stays the durable source of truth; the harness session is an ephemeral cache, reset on any doubt.

Tools are model-facing workflows dispatched by `ToolRegistry` under the turn's authority. Every `Tool` maps its decoded input to one concrete effect descriptor, and its implementation can only run with the matching non-escapable token. The registry authorizes that effect before invoking the tool; `AnyTool` preserves the concrete effect type through type erasure. Agent-facing effect domains live in `HailCore`.

## Topics

### Agents

- ``Agent``
- ``AgentID``
- ``Role``
- ``AgentContextID``
- ``AgentSpawnConfig``
- ``AgentDefinition``
- ``AgentActivity``
- ``AgentStream``

### Models

- ``ModelEndpoint``
- ``SessionOwningEndpoint``
- ``TurnDelta``
- ``KimiCodeEndpoint``
- ``ClaudeCliEndpoint``
- ``CodexAppServerEndpoint``
- ``AnyLanguageModelEndpoint``
- ``ModelCatalog``
- ``LLMMessage``
- ``LLMResponse``
- ``LLMToolCall``

### Tools

- ``Tool``
- ``ToolRegistry``
- ``FileTool``
- ``AgentTool``

### Effects

- ``FileEffect``
- ``TerminalEffect``
- ``ProcessEffect``
- ``NetworkEffect``
- ``CoordinationEffect``
- ``ClockEffect``
- ``TurnAuthorityLane``
