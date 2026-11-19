# ``HailAgentRuntime``

Agents as distributed, virtual, event-sourced actors, and the runtime that answers their turns.

## Overview

An ``Agent`` is a distributed virtual actor: reached by its identity, activated when a message
arrives, passivated when idle, and recovered from its journal. It handles one turn at a time; the
model's tool calls are answered inside the same model request.

The host installs ``AgentRuntimePlugin`` on its cluster node, with its definitions, tools, models,
workspaces, authority and context compaction. ``AgentStream`` follows a turn while it runs, typed.

Before each model request, the history is assembled into a prompt and, when it nears the model's
window, compacted by the host's ``ContextCompactor``.

## Topics

### Agents

- ``Agent``
- ``AgentRuntimePlugin``
- ``AgentStream``
- ``AgentConnection``
- ``ActiveAgentIndex``

### Agents asking agents

- ``AgentTool``
- ``AgentDeliveryTracker``
- ``AgentDeliveryID``
- ``AgentDeliveryStatus``

### Context

- ``AgentContextProvider``
- ``PromptAssembler``
- ``ContextManifest``
- ``ContextCompactor``
- ``CompactionBudget``
- ``CompactionDecision``
- ``RequestMeasurer``
