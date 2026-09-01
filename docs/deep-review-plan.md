# Fix plan — Hail deep-review findings

Fixes for the verified findings from the deep code review, in priority order.
Scope: all High and Medium findings plus the two trivial Low fixes. Deferred
(documented at the end): riskier/low-value items that need design decisions.

> **Status (2026-08-13): all phases implemented.** Phases 1-6 landed as planned;
> Phase 7 was slimmed to Hail-owned failure modes only (cluster-level scenarios
> deferred to stagehand integration tests, where a real cluster exists). The
> failure-injection suite caught one real production bug beyond the plan:
> `ACPSession.executePrompt` could drop a turn's final text chunk (finish race
> between the prompt stream and the notification router) — fixed by finishing
> the stream on the actor, serialized with notification routing. Final state:
> 40 HailTests + 21 ScopedEffectTests, all green.
> Lane-authority note (Phase 5): investigation showed enforcement already
> happens per-stream (`ReasoningLoop` passes `lane?.authority ?? authority` to
> `SessionOwningEndpoint.stream` on every turn); the fix was documenting the
> invariant and pinning it with tests, not changing the resolution flow.

## Phase 1 — Cancellation propagation

**1a. ACP: send `session/cancel` when the consumer cancels.**
- `Sources/HailModelRuntime/LLM/AnyLanguageModel/ACPSession.swift` (`executePrompt`, ~line 427):
  the prompt runs in an unstructured `responseTask`; `streamContinuation.onTermination`
  currently only cancels the watchdog. Add: on `.cancelled` termination, cancel
  `responseTask` and send `try? await client.cancelSession(sessionId:)` (API confirmed
  in swift-acp `Client.swift:378`), so the harness stops executing effects.
- `ACPModelEndpoint.swift` (~line 292): the wrapper awaiting `responseTask.value` must
  unblock on consumer cancellation — race the await against cancellation (or use
  `withTaskCancellationHandler`) and map the outcome to `ModelEvent.failed(.cancelled)`
  instead of lingering until turn end.

**1b. Codex: classify cancellation as cancelled, not disconnect.**
- `CodexAppServerSession.swift` (~line 260): when the event loop ends due to consumer
  cancellation (`Task.isCancelled`), throw a dedicated `CodexSessionError.cancelled`
  instead of falling through to `.disconnected`; don't tear down the connection on
  cancellation in `runTurn`'s catch (~line 92).
- `CodexAppServerEndpoint.swift` (~lines 141-143): map `.cancelled` to
  `ModelEvent.failed(.cancelled)` rather than `.requestFailed`.

**1c. ReasoningLoop: check cancellation, cap tool rounds.**
- `Sources/HailAgentRuntime/Reasoning/ReasoningLoop.swift` `runTurn` (line 308):
  add `try Task.checkCancellation()` at the top of `while true` and after
  `registry.execute`; add a max tool-round cap (e.g. 25, constant with a doc comment)
  that throws `AgentRuntimeError.modelMisbehavior` when exceeded.
- Error mapping (~lines 158-164, 480-487): `CancellationError` must map to
  `AgentRuntimeError.cancelled` (not `modelMisbehavior`) and must **not** be journaled
  as `turnFailed` into the conversation thread.

**1d. ToolRegistry: rethrow cancellation.**
- `Sources/HailCore/Tools/ToolRegistry.swift` (line 105): add
  `catch is CancellationError { throw }` before the catch-all so a cancelled turn
  aborts the tool round instead of returning a model-visible error and continuing.

Tests: extend the stall-watchdog/routing test style — a stub ACP agent test asserting
`session/cancel` is sent on consumer cancellation; a ReasoningLoop-level test that a
cancelled stream journals no `turnFailed`; a ToolRegistry test that cancellation
propagates. (New test file must be added to `Package.swift` `HailTests` sources —
sources are listed explicitly.)

## Phase 2 — Crash-recovery dedup (AgentState)

- `Sources/HailCore/Agent/AgentState.swift`:
  - `case .turnStarted` (line 59): stop clearing `pendingTurnRerun` here; keep it so
    the re-run's opening message can be recognized.
  - `case .messageReceived` (line 62): collapse when the message equals
    `pendingTurnRerun` (same content + timestamp, so genuinely repeated messages with
    fresh timestamps are kept), and on collapse set `activeTurn?.opening = message`
    and clear `pendingTurnRerun`. Keep the existing `conversationThread.last != message`
    guard as a secondary check. Also clear `pendingTurnRerun` when a *non*-matching
    opening arrives (stale rerun marker).
  - Verify `Agent.swift:124-125` still reads `pendingTurnRerun` before the re-run
    stream emits `turnStarted` (it does — ordering unchanged).
- Update the doc comment on `pendingTurnRerun` (lines 19-22) to describe the new
  clearing point.
- Test: journal `turnStarted, messageReceived, toolInvoked, toolResult`, replay,
  re-run the turn, assert the opening message appears exactly once in
  `conversationThread` (regression: today it appears twice).

## Phase 3 — AgentTool phantom spawns + directory lifecycle

- `Sources/HailAgentRuntime/Tools/AgentTool.swift` (~line 128): before
  `virtualActors.getActor`, check the target against the agent directory
  (`AgentRuntimePlugin.allAgents()` / the directory the plugin maintains); throw
  `AgentRuntimeError.modelMisbehavior("Unknown agent id …")` for unknown ids so the
  implementation matches the doc comment at lines 123-127.
- `Sources/HailAgentRuntime/Agent/AgentRuntimePlugin.swift`: `unregister(agentID:)`
  (line 225) exists but has no caller — call it from `Agent.shouldDeactivate()`
  (`Sources/HailAgentRuntime/Agent.swift:151`) when deactivation is accepted, so
  `list_agents` stops reporting passivated agents.
- Test: sending to an unknown id fails with the error and does not create a directory
  entry; after deactivation the agent no longer appears in `allAgents()`.

## Phase 4 — `Classified` reflection leak

- `Sources/ScopedEffect/Classified.swift`: add
  `extension Classified: CustomReflectable { public var customMirror: Mirror { Mirror(self, children: []) } }`
  so `dump`/Mirror-based loggers cannot reach the stored value.
- Test in `Tests/ScopedEffectTests`: `String(reflecting:)` / `dump` output contains no
  secret bytes.

## Phase 5 — `shouldDeactivate` reentrancy + lane authority + stall ceilings

- `Sources/HailAgentRuntime/Agent.swift:151-166`: after the `await evictEndpoint(...)`
  suspension, re-check `self.isWorking`; if a turn started during the eviction window,
  skip deactivation (return false). Note in a comment that the endpoint was already
  evicted in that case — the next turn rebuilds it, which is safe.
- **Lane authority on endpoint resolution** (`Agent.swift:398-408`): the `endpoint`
  closure passes `authority: self.authority` even when a `lane` is set, while cached
  and stateless endpoints keep creation-time authority
  (`AgentRuntimePlugin.swift:156-158`). A laned turn — stagehand's reviewer
  (read-only), worker (worktree-pinned), and untrusted-input (deny-all) lanes are
  the product's security model — must never run effects under the broader default
  authority. Fix: resolve/build the endpoint with the lane-derived authority (and
  key any endpoint cache on the authority identity, not just model+agent), or pass
  the lane authority through per-stream for session-owning endpoints and verify the
  endpoint honors it over its creation-time authority. Add a test asserting an
  untrusted-input-laned turn's effects are all denied even when a warm endpoint
  exists. Verify end-to-end from stagehand's untrusted-comment path after the Hail
  fix lands.
- Codex stall ceiling: `CodexAppServerClient.request` (`CodexAppServerClient.swift:84-104`)
  parks its continuation with no timeout — add an idle ceiling (reuse the pattern from
  `ACPSession.watchForStall`: activity clock + probe interval, configurable like
  `maxStallDuration`) that fails the pending request and resets the connection.
  `Timeout.swift`'s `withTimeout` has its own leak (sleep task never cancelled when the
  operation wins, ~lines 37-50) — fix that first (cancel the sleep in a `defer` /
  cancellation handler) and reuse it, or implement the ceiling inline; pick whichever
  is smaller.
- Claude stall ceiling: wrap `ClaudeCliEndpoint.runTurn`'s subprocess wait
  (`ClaudeCliEndpoint.swift:318-404`) in the same timeout so a hung `claude -p`
  fails the turn instead of blocking forever.
- Tests: mirror `KimiCodeStallWatchdogTests` with a wedged Codex stub and a hung
  Claude stub, asserting the turn fails at the ceiling (assert elapsed >= ceiling and
  error identity, fixing the weak `any Error` assertion pattern noted in the review
  for the new tests).

## Phase 6 — Test-infrastructure hardening (cheap, prevents flakes)

- `Tests/ScopedEffectTests/EffectAuthorityTests.swift:120-146`: move
  `EffectAudit.install(nil)` cleanup into `defer`; replace unchecked `recorded[0]`/`[1]`
  indexing with `#require(recorded.count == 2)`; add `.serialized` to
  `EffectAuditStressTests` too (or merge both into one `.serialized` suite) so the
  process-global observer can't be swapped mid-flight by a parallel suite.
- `Tests/HailTests/ClaudeCliSessionRoutingTests.swift:176-226`: make the stub log the
  `--resume` attempt before exiting, and assert the resume was attempted (the claimed
  retry path is currently unobservable).
- `Tests/HailTests/KimiCodeStallWatchdogTests.swift:106-112`: assert the error is the
  stall-ceiling reset (not `any Error`) and add a lower-bound elapsed check.

## Phase 7 — Failure-injection suite (protects stagehand's shipped guarantee)

Stagehand's README sells "crash recovery: journal replays on restart, resumes
exactly where it left off" — that property *is* Hail's replay/re-run code, and it
is currently proven only against cooperative stubs. Scope is Hail-owned failure
modes only; cluster-level failures are the framework's problem and are deferred
to stagehand integration tests, where a real cluster exists.

Covered (`Tests/HailTests/FailureInjectionTests.swift`):

- **SIGKILL mid-turn (ACP)** — done. Stub harness killed while a prompt is in
  flight: the turn fails with `ClientError.processFailed` (no hang), the
  session is reset (`currentSessionID == nil`), and the next turn cold-starts a
  fresh harness process and succeeds.
- **SIGKILL mid-turn (Codex)** — done. Same crash against
  `CodexAppServerSession`: transport EOF ends the turn's event stream and the
  turn surfaces `CodexSessionError.disconnected`; the durable thread id
  survives, and the next turn relaunches the process and resumes the thread
  (`thread/resume`) instead of re-bootstrapping.
- **Protocol-violating harness (ACP)** — done. (a) Malformed JSON-RPC
  mid-session is dropped at swift-acp's decode boundary; the parked turn then
  fails via the stall watchdog with `ClientError.processNotRunning` after the
  probe also fails, the session resets, and a fresh session recovers.
  (b) Garbage before any request (plain non-JSON line, unsolicited
  `session/update` for a ghost session, response for a nonexistent request id,
  unknown notification) is contained — the turn and a following warm turn
  proceed normally, proving the violation poisons neither the session nor the
  single notification consumer.
- **Repeated crash dedup (AgentState fold)** — done. Two consecutive
  interrupted re-runs of the same opening (crash after tool events, re-run,
  crash again, re-run): the opening still appears exactly once in
  `conversationThread`, pinning the Phase 2 fix against compounding
  duplication.
- **Truncated/corrupted journal (decode boundary)** — done at the fold/replay
  level: a torn tail line and a syntactically valid but unknown event both
  throw `DecodingError` loudly and never partially apply; replay through the
  last valid event recovers the exact pre-crash state (including
  `pendingTurnRerun` and the journaled session identity used by the resume
  path). Torn-line framing/repair is the EventStore's job — bring-your-own,
  out of this package's scope; noted in a comment on the suite.

Production bug found and fixed by this suite: `ACPSession.executePrompt`
finished the prompt event stream synchronously in `responseTask`'s `defer`,
racing the notification consumer's routing of the turn's final chunk — a
short reply (chunk flushed together with the `session/prompt` response)
could be dropped as a yield-after-finish, and `ACPModelEndpoint` builds
plain-text output from that stream text. First fixed by finishing the stream
via an actor hop (`finishPromptStreamAfterRouting`) — but that only narrowed
the race: the chunk reaches the actor via a separate notification-consumer
task whose wake-up is unordered with the response task's, so the finish hop
could still win the mailbox. The final fix finishes the stream only after
routing has been quiet for a full check interval
(`finishPromptStreamWhenRoutingSettles`, comparing `lastRoutedAt` against a
monotonic `ContinuousClock`):
swift-acp yields every pre-response chunk before resuming the response and
the consumer drains FIFO, so post-response quiescence proves the trailing
chunk was routed. Also folded in: the watchdog `ActivityClock`/`ProbeFlag`/
`CodexActivityClock` Mutex boxes were removed (every access is already
actor-isolated) and stall timestamps moved to monotonic `ContinuousClock`.

Deferred to stagehand integration tests (needs a live cluster; not Hail-owned):
downed `EventStore` singleton mid-turn, agent-process SIGKILL with
virtual-actor reactivation, and multi-node failover/topology variants of the
same scenarios.

## Out of scope (deferred, needs design decisions)

- Effect-policy hardening (`Effects.swift` basename/lexical containment): currently
  unused in-repo; tightening it is a security-API design task, not a bug fix.
- `AgentID` hyphenated-role parsing: needs a validation/escaping decision at the
  role-definition boundary.
- `FileTool.replace` multi-occurrence behavior: changing it alters tool semantics the
  model may rely on; propose separately.
- ~~Lane-authority endpoint caching~~ — **promoted into Phase 5** (stagehand's
  lanes make it a live security concern, not a theoretical one).
- Codex thread accumulation, activity-cancel mailbox race: real but
  lower-frequency; address after the above.
- `FileEventStore` torn-tail hardening in stagehand (skip/repair a partial final
  JSONL line on replay): no production call sites today; fix if it ever becomes
  someone's default store.

## Verification

- `swift build` clean after each phase.
- Full `swift test` at the end (plus targeted runs per phase); all existing tests must
  stay green, new regression tests for Phases 1-5 must pass.
