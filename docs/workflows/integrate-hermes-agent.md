---
title: Integrate Hermes Agent
type: workflow
status: planned
last_updated: 2026-05-09
sources:
  - decisions/0004-hermes-agent-integration.md
  - concepts/hermes-agent.md
tags: [hermes, mcp, sidecar, brain, workflow]
---

# Integrate Hermes Agent

The implementation plan for ADR 0004. Six milestones (HM1-HM6),
each end-to-end testable. Cadence and granularity match the
M1-M8 convention from `~/.claude/plans/i-d-like-this-to-swirling-octopus.md`.

Read [ADR 0004](../decisions/0004-hermes-agent-integration.md) for the
*why* and [`concepts/hermes-agent.md`](../concepts/hermes-agent.md)
for the *what*. This page is the *how*.

## Goal

Ship a Settings → Brain → Backend toggle that swaps Rocky's LLM
turn loop between the existing local LM Studio path and a new
Hermes-driven path. Hermes runs as a Rocky sidecar; Rocky exposes
its tools to Hermes over MCP. Voice, motion, TTS, and cockpit UX
are unchanged.

## Hard constraints (from ADR 0004)

These are checks you must run before merging each milestone:

- [ ] Sidecar contract honoured. Anything Python-side flows through `SidecarHost`.
- [ ] LM Studio default path unchanged. First-token-to-speech < 1.5 s.
- [ ] Robot safety: only one backend holds the `MotionMutex` at a time.
- [ ] No second chat surface. The cockpit conversation panel renders
      both backends identically.
- [ ] Swift 6 strict concurrency clean. No `@unchecked Sendable`.
- [ ] Persona migration handled. v5 installs migrate to v6 cleanly.
- [ ] Memory: mempalace paused (not deleted) when Hermes is active.

## Milestones

Each milestone has: scope, files to create/modify, tests, validation
on the actual robot, and a "done when" gate. Don't start the next
milestone until the previous one's gate is met.

---

### HM1 — `MCPHost` package: Rocky-as-MCP-server (~5 days)

**Scope.** A new Swift package that exposes `ToolRegistry` over the
Model Context Protocol stdio transport. No Hermes yet — this stands
alone and can be tested with any MCP client (e.g. Claude Desktop) before
HM2.

**New files.**

- `Sources/MCPHost/MCPHost.swift` — entry point, `MCPServer` actor.
- `Sources/MCPHost/MCPProtocol.swift` — JSON-RPC 2.0 envelope types
  (`MCPRequest`, `MCPResponse`, `MCPNotification`, `MCPError`),
  Codable.
- `Sources/MCPHost/MCPMethods.swift` — `initialize`, `initialized`,
  `tools/list`, `tools/call`, `notifications/tools/list_changed`.
  One method-handler each.
- `Sources/MCPHost/MCPTransport.swift` — stdio reader/writer.
  Newline-delimited JSON over `FileHandle.standardInput` /
  `.standardOutput`. The serialisation is a `JSONLineCodec`-shaped
  loop, but for JSON-RPC envelopes (no envelope re-shape; MCP is
  already JSON-RPC).
- `Tests/MCPHostTests/MCPHostInitializeTests.swift` — handshake.
- `Tests/MCPHostTests/MCPHostToolsTests.swift` — `tools/list`
  matches `ToolRegistry.schemas`, `tools/call` round-trips a
  `look_at` invocation against a fake `ToolRegistry`.
- `Tests/MCPHostTests/MCPHostCancelTests.swift` — cancellation
  propagates from the transport into in-flight calls.

**Modified files.**

- `Package.swift` — add `MCPHost` target + test target. Depend on
  `Cognition` (for `ToolRegistry`) and `Telemetry` (for `LogBus`).
- `Sources/Telemetry/TelemetryEvent.swift` — add
  `mcpRequest(method:summary:)`, `mcpResponse(method:latencyMs:ok:)`
  cases. Update every consumer (LogsView, MomentFeed, archive) per
  the closed-set rule.
- `Sources/Rocky/AppServices.swift` — add a `mcpHost: MCPHost?`
  optional service field. Not started in this milestone (no consumer
  yet); the field exists so HM2 can wire it.

**Wire format reminders.**

MCP runs over JSON-RPC 2.0. Envelopes look like:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
{"jsonrpc":"2.0","id":1,"result":{...}}
{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"..."}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

The transport is **newline-delimited JSON** like `JSONLineCodec`. We
don't reuse `JSONLineCodec` directly because MCP requires a strict
JSON-RPC envelope and our existing codec wraps an internal envelope
(`{id, method, params, result, ...}`); but the line-handling logic
is the same shape, so subclass / parameterise where helpful.

**`tools/list` response shape.** MCP's `Tool` is:

```json
{
  "name": "look_at",
  "description": "Make Rocky orient...",
  "inputSchema": { "type": "object", "properties": {...}, "required": [...] }
}
```

`ToolRegistry.schemas` returns OpenAI-shaped tool schemas
(`ToolSchema.function.parameters` → JSON-Schema object). Re-shape:
`name = function.name`, `description = function.description`,
`inputSchema = function.parameters`. No data loss.

**`tools/call` request shape.** MCP sends:

```json
{ "name": "look_at", "arguments": { "yaw_deg": 30, "duration_s": 1.5 } }
```

Map to `ToolRegistry.invoke(name:argumentsJSON:llmMessageId:)`.
Construct `argumentsJSON` from the `arguments` object via
`JSONSerialization`. Use `llmMessageId` = `"mcp-\(requestId)"` so
telemetry distinguishes MCP-driven invocations from LLM-driven ones.

**Tests.**

- `Tests/MCPHostTests/MCPHostInitializeTests.swift` — protocol-version
  negotiation, capabilities echo.
- `Tests/MCPHostTests/MCPHostToolsTests.swift` — register a handful
  of tools in a fake `ToolRegistry`; assert `tools/list` shape;
  assert `tools/call` invokes the right handler with the right args
  and returns the result envelope.
- `Tests/MCPHostTests/MCPHostCancelTests.swift` — start a long
  `tools/call`, cancel via JSON-RPC `$/cancelRequest`, verify the
  underlying `Task` is cancelled.
- `Tests/MCPHostTests/MCPHostTelemetryTests.swift` — every request
  emits one `mcpRequest`, every response emits one `mcpResponse`.

**Validation.**

End-to-end with **Claude Desktop** as the MCP client:

1. Build Rocky with `MCPHost` enabled.
2. Add Rocky to Claude Desktop's `mcpServers` config:
   ```json
   {
     "mcpServers": {
       "rocky": {
         "command": "/path/to/build/Rocky.app/Contents/MacOS/MCPHost",
         "args": []
       }
     }
   }
   ```
3. In Claude Desktop, ask "what time is it?" — it routes to Rocky's
   `get_current_time`.
4. Ask Claude Desktop to "make Rocky look left" — it routes to
   `look_at` and the head moves.

**Done when.**

- [ ] `swift test --filter "MCPHost"` passes.
- [ ] Claude Desktop discovers Rocky's tools.
- [ ] `look_at` driven via Claude Desktop → robot moves.
- [ ] Telemetry shows `mcp_request` / `mcp_response` events.

---

### HM2 — `Sidecars/hermes/`: the Hermes sidecar (~4 days)

**Scope.** Wrap Hermes Agent as a Rocky sidecar honouring ADR 0003's
contract. No Swift consumer yet — at the end of this milestone, the
sidecar starts, accepts the contract's wire (line-delimited JSON
over stdin/stdout), and proxies messages to/from a running Hermes
chat session.

**New directory: `Sidecars/hermes/`.**

```
Sidecars/hermes/
   manifest.json
   pyproject.toml          # `hermes-agent` is the only dep, plus pydantic for the wire envelope
   uv.lock
   setup.sh                # idempotent: install Hermes into ~/.hermes-rocky/, generate mcp.toml
   install_hermes.sh       # checked-in, pinned-SHA download of upstream install.sh
   install_hermes.sha256   # the expected hash of install_hermes.sh
   mcp.toml.template       # template for ~/.hermes-rocky/mcp.toml — points at Rocky's MCPHost
   rocky_hermes/
      __init__.py
      runner.py            # the wire adapter; speaks line-JSON to Swift, drives Hermes
      hermes_io.py         # subprocess-bridge to the `hermes` CLI's interactive mode
```

**`manifest.json` shape.**

```json
{
  "name": "hermes",
  "version": "0.1.0",
  "binary": "{venv}/bin/python",
  "args": ["-u", "-m", "rocky_hermes.runner"],
  "working_dir": "{sidecar_dir}",
  "env": {
    "HERMES_HOME": "~/.hermes-rocky",
    "HERMES_NO_TELEMETRY": "1",
    "ROCKY_MCP_BINARY_PATH": "/Applications/Rocky.app/Contents/MacOS/MCPHost"
  },
  "ready_event": "ready",
  "ready_timeout_s": 60,
  "shutdown_grace_s": 5,
  "restart_policy": "on_failure",
  "restart_max_per_minute": 3,
  "timeouts": {
    "*": 10,
    "chat": 60,
    "model_list": 15,
    "warm_up": 30
  }
}
```

**`setup.sh` (idempotent).**

Four steps, in order:

1. Verify `shasum -a 256 install_hermes.sh` matches
   `install_hermes.sha256`. Abort if not — never curl-pipe-bash a
   live URL whose contents we haven't audited.
2. If `$HERMES_HOME/bin/hermes` doesn't exist, run
   `HERMES_HOME=~/.hermes-rocky bash install_hermes.sh`.
3. Build the Rocky-side venv for the wire adapter via
   `uv venv $VENV --python 3.12 && uv pip install --requirement <(uv export --frozen)`.
4. Generate `~/.hermes-rocky/mcp.toml` from `mcp.toml.template`,
   substituting `@ROCKY_MCP_BINARY@` with the resolved
   `Rocky.app/Contents/MacOS/MCPHost` path.

**`runner.py` methods** (sidecar wire contract over line-JSON):

| Method | Returns |
|---|---|
| `warm_up` | `{"ok": true}` |
| `list_models` | `{"models": [...]}` |
| `set_model(provider, name)` | `{"ok": true}` |
| `set_persona(prompt)` | `{"ok": true}` |
| `chat(text)` | stream of `{"delta": "..."}`, terminated by `stream_end` |
| `reset` | `{"ok": true}` |
| `set_provider_key(provider, key)` | `{"ok": true}` |

`runner.py` owns the `hermes` CLI subprocess (interactive mode) and
translates between the line-JSON wire contract and Hermes' stdin/stdout.

**Tests.**

- `Tests/SidecarHostTests/HermesSidecarIntegrationTests.swift` —
  marked `@available(*, *)` and gated on a build flag because it
  requires Hermes installed. Spawns the sidecar with a stub
  `HERMES_HOME` configured to use a "fake provider" that returns
  canned responses. Asserts: ready event fires, `chat("hi")` streams
  deltas, `reset()` clears, `kill -9` triggers supervisor restart
  within 3s.
- `Tests/SidecarHostTests/HermesSidecarSetupTests.swift` — exercises
  `setup.sh` against a temp `HERMES_HOME`. Verifies the SHA check
  fails if `install_hermes.sh` is tampered with.

**Validation.**

1. Run `./Sidecars/hermes/setup.sh` on a fresh Mac.
2. Confirm `~/.hermes-rocky/bin/hermes --version` works.
3. Manually drive the sidecar with `printf` to its stdin:
   ```bash
   echo '{"id":"1","method":"warm_up","params":{}}' | \
     "$HOME/Library/Application Support/Rocky/sidecars/hermes/.venv/bin/python" \
     -m rocky_hermes.runner
   ```
   should print `{"event":"ready"}` then `{"id":"1","result":{"ok":true}}`.
4. `swift test --filter "Hermes"` passes (with the build flag set).

**Done when.**

- [ ] `setup.sh` is idempotent and verified.
- [ ] The sidecar starts under `SidecarSupervisor`.
- [ ] `kill -9` recovery works within 3 s (matches echo sidecar SLA).
- [ ] `mcp.toml` points at Rocky's `MCPHost` binary.

---

### HM3 — `BrainBackend` protocol + `LMStudioBrain` extraction (~3 days)

**Scope.** Refactor the existing cognition surface behind a
protocol so a second backend can plug in without touching everywhere.
No Hermes consumer yet; the existing LM Studio path keeps working
identically.

**New files.**

- `Sources/Cognition/BrainBackend.swift` — the `BrainBackend`
  protocol from the concept doc. The `BrainOutput` enum (renamed
  from `CognitionEngine.Output`).
- `Sources/Cognition/LMStudioBrain.swift` — wraps the existing
  `CognitionEngine` 1:1 to satisfy `BrainBackend`. Forwards every
  call. The actual cognition logic stays in `CognitionEngine`.

**Modified files.**

- `Sources/Cognition/CognitionEngine.swift` — make `Output` a
  type alias for `BrainOutput`. No semantic change.
- `Sources/Rocky/AppServices.swift`:
  - Replace `let cognition: CognitionEngine` with
    `var brain: any BrainBackend`.
  - `init` constructs a `LMStudioBrain` by default.
  - Change every callsite that did `await cognition.send(...)` to
    `await brain.send(...)`. There are three (line 1156, 1274,
    1656) — each is a one-liner.
- `Sources/Rocky/SettingsStore.swift` — add a new key:
  `var brainBackend: String { didSet { save() } }` defaulting to
  `"lm-studio"`. Persisted under `"rocky.brain.backend"`.

**Tests.**

- `Tests/CognitionTests/BrainBackendTests.swift` — assert that
  `LMStudioBrain` and `CognitionEngine` produce identical
  `AsyncThrowingStream<BrainOutput, Error>` for the same inputs.
- All existing Cognition tests pass unchanged.

**Validation.**

1. `swift build` clean.
2. `swift test` — all 53+ existing tests pass.
3. Smoke test: launch `Rocky.app`, say "Rocky, hello" — same
   behaviour as before.

**Done when.**

- [ ] No regression in existing tests.
- [ ] Smoke test: full voice → brain → TTS → robot speaker round
      trip works on the LM Studio path.

---

### HM4 — `HermesBrain` (~5 days)

**Scope.** Implement `HermesBrain` over the `hermes` sidecar from
HM2 and the protocol from HM3. Wire it through Settings.

**New files.**

- `Sources/Cognition/HermesBrain.swift` — owns the `HermesSidecar`
  reference (a `Sidecar` from `SidecarHost`); maps `BrainBackend`
  methods onto sidecar `send`/`stream` calls.
- `Sources/Cognition/HermesSidecar.swift` — typed adapter, modelled
  on `MemoryService`. Methods: `warmUp`, `listModels`, `setModel`,
  `setPersona`, `chat` (stream), `reset`.
- `Sources/Rocky/HermesSettingsView.swift` — Settings → Brain →
  Hermes provider/key panel; writes config into
  `~/.hermes-rocky/config.toml` via the sidecar.

**Modified files.**

- `Sources/Rocky/AppServices.swift`:
  - Add `let hermesSidecar: any Sidecar` (constructed but not
    started until the user picks Hermes; `restart_policy` honours
    on-demand startup).
  - Add `let hermesBrain: HermesBrain` (lazy / opt-in).
  - Add `func switchBackend(to: String) async`. The fenced
    backend switch:
    1. Pause `voice` (no new turns).
    2. Wait for any in-flight `brain.send(...)` to finish.
    3. `await currentBrain.releaseMotionMutex()`.
    4. If switching to Hermes, `try await hermesSidecar.start()`.
    5. Update `self.brain` to the new backend.
    6. `await newBrain.acquireMotionMutex()`.
    7. Resume `voice`.
  - Add `motionMutex: BackendID?` field. The robot tools (`look_at`,
    `play_emotion`, etc.) check it before dispatch.
- `Sources/Rocky/SettingsView.swift` — add a Brain → Backend picker.
  Writes `settings.brainBackend`. On change, calls
  `services.switchBackend(to:)`.
- `Sources/Memory/MemoryService.swift` — add `setActive(_ on: Bool)
  async` that flips a flag; `recall`/`record` early-return when
  inactive (mempalace process keeps running, just doesn't transact).
- `Sources/Rocky/AppServices.swift` — when switching to Hermes,
  call `memory.setActive(false)`; when switching back, `setActive(true)`.

**Robot safety: the `MotionMutex`.**

The mutex is a `MainActor`-bound `BackendID` on `AppServices`
(`enum BackendID: String, Sendable { case lmStudio, hermes }`).
Every robot-touching tool handler — `look_at`, `play_emotion`,
`wake_up`, `go_to_sleep`, `stop_motion`, `pause_face_tracking`,
`resume_face_tracking`, `express`, `set_motor_mode`, `say`,
`stop_speaking` — gets a guard at the top that returns
`{"ok": false, "error": "backend not active"}` if the caller's
backend doesn't hold the mutex.

Tool handlers don't currently know "who called them." We add a
minimal calling-context indirection: `BrainBackend.invoke` wraps
`ToolRegistry.invoke` and tags the call with the backend's ID via a
`@TaskLocal`. Tool handlers read that task-local in the guard.

**Persona migration.** `SettingsStore.currentPersonaVersion` bumps to
6. The current `defaultPersona` (LM Studio + fenced-JSON) is preserved.
A new `defaultHermesPersona` static is added — same Rocky voice rules
and speaking rules, but the "ACTING WITH TOOLS" section explains MCP
invocation instead of fenced JSON. Migration writes both prompts on
upgrade. The active persona depends on the active backend.

**Settings → Brain → Backend UX.** Radio: `LM Studio (default)` |
`Hermes (advanced)`. Selecting Hermes when its venv is missing shows
an "Install Hermes" button; clicking runs `setup.sh` via
`FirstRunSetup`. Below the radio, the active model/provider panel
for the chosen backend. Hermes adds a Provider dropdown
(populated from `hermes model list`) and a latency hint if the chosen
model is known to exceed 1.5s first-token.

**Tests.**

- `Tests/CognitionTests/HermesBrainTests.swift` — fake
  `HermesSidecar` with deterministic responses. Assert
  `BrainBackend.send` produces the expected stream.
- `Tests/CognitionTests/MotionMutexTests.swift` — register a fake
  tool that touches motion; switch backends mid-call; assert the
  inactive backend's tool call returns `backend not active`.
- `Tests/RockyTests/BackendSwitchTests.swift` — full backend swap
  drains in-flight, swaps mempalace state, swaps persona.

**Validation on the robot.**

1. Default install: LM Studio path. Voice → Gemma → robot. Same as today.
2. Settings → Brain → Hermes. Click "Install Hermes." Wait
   ≤ 60 s for setup.
3. Pick a Hermes provider + model (e.g. Groq + Llama-3.3-70B).
4. Say "Rocky, what time is it?" → robot says the time.
5. Watch the LogBus: events show `mcp_request(get_current_time)` →
   `mcp_response`, then `hermes_event(chat_completion)` → `say`.
6. Switch back to LM Studio. Verify the conversation flows there
   again, mempalace count is incrementing, no Honcho activity.

**Done when.**

- [ ] Switching backends is < 2 s and never strands the robot
      mid-motion.
- [ ] Same voice → STT → wake → say → TTS → robot path works on
      both backends.
- [ ] mempalace pauses when Hermes is active; resumes when LM
      Studio is active.
- [ ] Cockpit shows the same conversation panel on both backends.

---

### HM5 — Polish, calibration, latency surfacing (~3 days)

**Scope.** The Hermes path is functional after HM4. HM5 makes it
feel as good as the LM Studio path.

**Tasks.**

- Run every Hermes `assistantFinal` through
  `CognitionEngine.cleanupForTTS` (already public) so quote-wrapping
  and abbreviation expansion behave identically.
- Apply the dedup ledger pattern from `CognitionEngine.runTurn`
  ([line 144](../../Sources/Cognition/CognitionEngine.swift#L144))
  inside `HermesBrain` — Hermes tends to fire MCP tool calls more
  aggressively than Gemma.
- Add a first-token latency badge to the cockpit's portrait area
  (`Sources/Rocky/Cockpit/PortraitView.swift`), reading from the
  same `firstChunkMs` field both backends already publish in
  `assistantFinal`.
- Settings → Brain → Hermes provider-key panel
  (`Sources/Rocky/HermesSettingsView.swift`) — add/edit/remove
  provider keys via the sidecar's `set_provider_key` method (no
  direct shell-out).
- Inspector → Memory shows both stores with active/paused state.

**Tests.** `Tests/CognitionTests/HermesDedupLedgerTests.swift`
— repeated calls with identical args within a turn short-circuit.

**Done when.** No "feels slow" / "feels jerky" / "wrong voice"
complaints after 30 minutes of Hermes-mode use.

---

### HM6 — Hardening, docs, opt-in onboarding (~3 days)

**Scope.** Resilience tests, log cleanup, README and onboarding
update. Hermes ships opt-in; first-run unchanged.

**Resilience matrix.**

| Scenario | Expected |
|---|---|
| `kill -9` Hermes mid-turn | Supervisor restarts ≤ 3s; in-flight user turn surfaces an error; next turn works. |
| Hermes provider offline mid-stream | `HermesBrain` yields `.error("provider unreachable")`; cockpit shows it. |
| Switch backends mid-Hermes-turn | Switch waits for the turn to drain; no interleaving. |
| Memory swap | Paused mempalace stays at the same drawer count over a 10-min Hermes session; resumes on switch back. |
| Robot offline + Hermes active | `look_at` etc. return standard "robot offline" error MCP-side; Hermes tells the user. |

**Other tasks.**

- Telemetry archive rotates `mcp_request` / `mcp_response` /
  `brain_backend_switched` with the rest.
- Filter Hermes' stderr to `LogBus` at warn+ unless `Settings →
  Diagnostics → "Verbose Hermes logs"` is on.
- README.md gets a "Hermes (advanced)" subsection in the Cognition
  feature list, pointing at this doc and the ADR. Default install
  steps stay LM Studio.
- First-run flow unchanged. Hermes is discoverable in Settings.
- Optional `Help → "Switch to Hermes" tour` menu item walks new
  users through provider setup.

**Done when.**

- [ ] Resilience matrix all green.
- [ ] README updated.
- [ ] Onboarding unchanged for new users.
- [ ] Existing 53+ tests still pass; new HM1-HM5 tests pass.
- [ ] An hour of dogfood without a regression on either backend.

---

## Dependency adds

In rough order:

| Where | What | Why |
|---|---|---|
| `Sidecars/hermes/pyproject.toml` | `hermes-agent` (pinned) | The agent itself. |
| `Sidecars/hermes/pyproject.toml` | `pydantic >= 2.0` | wire envelopes |
| `Package.swift` | new target `MCPHost` | MCP server impl |
| `Package.swift` | new target `MCPHostTests` | tests |

Hermes' own transitive deps are isolated in its venv; they don't
bleed into Rocky's other Python sidecars.

## Persona migration sequence

1. The user is on persona v5 (current).
2. They update Rocky to the version with HM3 merged. App launch:
   `currentPersonaVersion = 6`. Migration writes `defaultPersona`
   (LM Studio variant, unchanged from v5) and the new
   `defaultHermesPersona` to UserDefaults. Sets version to 6. The
   user sees no persona change.
3. Later, the user switches to Hermes. The active prompt becomes
   `defaultHermesPersona`.
4. If the user customised v5 persona, their custom is preserved as
   the LM Studio prompt; the Hermes prompt is the in-code default.
   Settings → Brain → Persona has tabs for both, side by side.

## Tests you must add

Closed-set list. If you're touching files that aren't here, you may
have drifted from the plan.

- `Tests/MCPHostTests/MCPHostInitializeTests.swift`
- `Tests/MCPHostTests/MCPHostToolsTests.swift`
- `Tests/MCPHostTests/MCPHostCancelTests.swift`
- `Tests/MCPHostTests/MCPHostTelemetryTests.swift`
- `Tests/SidecarHostTests/HermesSidecarIntegrationTests.swift`
- `Tests/SidecarHostTests/HermesSidecarSetupTests.swift`
- `Tests/CognitionTests/BrainBackendTests.swift`
- `Tests/CognitionTests/HermesBrainTests.swift`
- `Tests/CognitionTests/HermesDedupLedgerTests.swift`
- `Tests/CognitionTests/MotionMutexTests.swift`
- `Tests/RockyTests/BackendSwitchTests.swift`

## Settings UI sketch

Settings → Brain gains a "Backend" radio at the top: `LM Studio (local,
fast, default)` vs. `Hermes (advanced; gateways, scheduler, skills)`.
Below the radio, a context-sensitive panel:

- **LM Studio panel** — unchanged from today: URL, model dropdown,
  API key, persona editor.
- **Hermes panel** — provider dropdown (`hermes model list`-driven),
  model dropdown filtered by provider, API key field, an info row
  with the typical first-token latency for the chosen model, and an
  "Install / Update Hermes" button that triggers the sidecar's
  `setup.sh` via `FirstRunSetup`. Hermes config lives at
  `~/.hermes-rocky/`; the panel surfaces that path.

The Persona editor is shared across backends: it has tabs for
"LM Studio" and "Hermes" so users can customise each prompt
separately. Default content for both comes from
`SettingsStore.defaultPersona` and `SettingsStore.defaultHermesPersona`.

## Risks and unknowns

- **MCP spec churn.** The protocol is young; expect breaking
  changes. We pin to a spec version in the `initialize` handshake;
  upgrades are explicit, not implicit.
- **Hermes `install.sh` SHA changes.** The pinned-SHA approach
  means a Hermes upstream upgrade requires a Rocky-side SHA bump
  in `install_hermes.sha256`. Document this in the workflow.
- **Persona drift.** The Hermes path may surface unexpected
  Hermes-default behaviours that bypass the persona. Track via
  the dogfood pass; tighten the persona iteratively.
- **Provider key storage.** Currently `~/.hermes-rocky/config.toml`
  is plain TOML. Migrating to Keychain is a follow-up if user
  feedback warrants it.

## See also

- ADR [0004 — Hermes Agent integration](../decisions/0004-hermes-agent-integration.md)
- [Hermes Agent (concept)](../concepts/hermes-agent.md)
- [Sidecar convention](../concepts/sidecar-convention.md)
- [Tools registry](../concepts/tools-registry.md)
- [Voice / listen pipeline](../concepts/voice-pipeline.md)
- Hermes Agent: <https://github.com/nousresearch/hermes-agent>
- Model Context Protocol: <https://spec.modelcontextprotocol.io>
