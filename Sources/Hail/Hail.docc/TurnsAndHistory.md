# Turns and history

What one input to an agent opens, what its history keeps, and what happens when a turn is cut
short.

## Overview

Each input opens one **turn**, and the turn closes with the agent's reply. Inside it, the model may
call tools: the agent answers those calls within the same model request, the way Apple's
Foundation Models runs tools inside `respond`, so a turn is never stopped and restarted to deliver
results.

### History

An agent's ``AgentHistory`` is its turns in order: each input, the tool calls and their results,
and the reply. Turns run one at a time, and at most one is open: the last.

The journal is the source of truth. Inputs, turn boundaries, tool calls and results, model requests
and replies are each recorded as they happen, so a new instance of the agent replays its journal
and continues from where the last one was.

### Recovery

A turn left open by a crash is resumed when the agent activates again, from what the journal
already holds. What a turn's ``AgentSpawnConfig`` says about interrupted turns decides whether
they're resumed or closed.

### When a turn is limited

When something limits a turn, the model is told in plain words, and the notice is journaled with
the turn:

- its answer ran out while it was thinking, after its tools answered;
- the turn made all the tool calls a turn may make (`maxToolRounds`).

### Watching the work

Model requests emit durable start, completion and failure records (``ModelRequestRecord``) with a
``TurnID``, a ``ModelRequestID``, their duration and the usage the provider reported. Read the live
``AgentStatusSnapshot`` and ``AgentActivity`` for the work in progress, and
``AgentUsageSummary`` for what an agent has used so far.
