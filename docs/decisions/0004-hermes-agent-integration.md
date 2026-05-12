---
title: "ADR 0004 — Hermes Agent integration"
type: decision
status: accepted
last_updated: 2026-05-12
tags: [decision, hermes, cognition, mcp, sidecar]
---

# ADR 0004 — Hermes Agent integration

> **Implementation status.** Decision accepted; implementation lives
> on the `hermes-agent` branch and has not been merged to `main` yet.
> The decision is recorded here so the catalog is contiguous and so
> the supporting [concept doc](../concepts/hermes-agent.md) and
> [workflow](../workflows/integrate-hermes-agent.md) are reachable
> from the wiki without checking out the branch.

## Date

2026-05-09 (decision). Backfilled to `main` 2026-05-12.

## Context

The user wants to integrate **Hermes Agent** (NousResearch, MIT,
[github.com/nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent))
into Rocky.

Hermes is not a library. It is a complete agent system with strong
opinions about who owns the conversation:

- A Python CLI (`hermes`) installed via curl-pipe-bash.
- Its own tool registry (40+ tools in "toolsets").
- Its own skills system (the `agentskills.io` standard, procedural memory).
- Its own persistent memory (Honcho dialectic user modeling, FTS5 search).
- Its own conversation history.
- Its own scheduler (cron-style).
- Subagent delegation.
- Provider-agnostic LLM (OpenAI / OpenRouter / Hugging Face / Nous Portal /
  NVIDIA NIM / etc.) — switch with `hermes model`.
- Messaging gateways: Telegram, Discord, Slack, WhatsApp, Signal, run as
  `hermes gateway`.
- Bidirectional MCP — `hermes mcp serve` exposes Hermes' conversations as
  a stdio MCP server; Hermes also consumes other MCP servers as tool sources.
- Multiple terminal backends (Local, Docker, SSH, Modal, Daytona, Vercel
  Sandbox).
- `~/.hermes/` holds skills, sessions, config.

Rocky has, today, in `Sources/`:

- A working LM Studio cognition turn loop ([CognitionEngine.swift:97-330](../../Sources/Cognition/CognitionEngine.swift#L97))
  including the Gemma fenced-JSON fallback ([CognitionEngine.swift:411-475](../../Sources/Cognition/CognitionEngine.swift#L411)).
- A closed-set tool registry ([ToolRegistry.swift](../../Sources/Cognition/ToolRegistry.swift))
  with 17 tools wired in ([AppServices.swift:1670-2006](../../Sources/Rocky/AppServices.swift#L1670)).
- A persona-tuned local memory store via the `mempalace` sidecar
  ([MemoryService.swift](../../Sources/Memory/MemoryService.swift)),
  recall + record stitched into the cognition turn
  ([CognitionEngine.swift:340-397](../../Sources/Cognition/CognitionEngine.swift#L340)).
- A persona prompt with versioned migration ([SettingsStore.swift:166-267](../../Sources/Rocky/SettingsStore.swift#L166)).
- A sidecar contract that every external Python process honours
  ([ADR 0003](0003-sidecar-convention.md)).

The crucial fact: **Hermes wants to own the conversation.** Embedding
it means deciding how much of Rocky's existing cognition (turn loop,
ToolRegistry, mempalace, persona) defers to it vs. stays separate.
This is the central design tension.

### Hard constraints

These come from `CLAUDE.md`, project memory, and the requesting user
brief, and they bound every option below:

1. **Sidecar contract is the invariant.** Anything Python-side runs through
   `SidecarHost`. No ad-hoc `Process.run`. ([sidecar-convention.md](../concepts/sidecar-convention.md))
2. **Voice latency.** First-token-to-speech under ~1.5 s on the existing
   setup. Voice → STT → wake → cognition → say → mlx-tts → robot speaker.
3. **Robot safety.** One owner of motion at any given moment. Two cognition
   systems stacking commands is forbidden ([feedback_robot_safety.md](file:~/.claude/projects/-Users-amplifiedai-Developer-learning-reachy/memory/feedback_robot_safety.md)).
4. **Calm-tech UX.** No redundant chat surfaces. The user talks to "Rocky"
   as one entity, even if Hermes is under the hood ([cockpit-design.md](../concepts/cockpit-design.md)).
5. **No abandonment of the current model.** Local LM Studio + Gemma 4 e4b
   stays the first-launch default. Hermes is opt-in.
6. **Swift 6 strict concurrency.** Whatever Swift surface this adds must
   fit `@Observable` + actors + `AsyncStream`.
7. **mempalace overlap.** Hermes ships its own memory; mempalace is
   already shipped. Pick one as authoritative or document a clear bridge.

### What changes if Hermes lands

Hermes lets Rocky reach a class of capabilities that today require code:

- Telegram / Discord / Signal / WhatsApp / Slack as input surfaces — the
  user can text "Rocky" from a phone and get the same brain.
- Persistent dialectic user modeling (Honcho).
- Procedural memory via skills (`agentskills.io`).
- Cron-scheduled actions ("at 09:00 daily, ask the user how they slept").
- A common MCP boundary so Claude Desktop / Cursor / Codex can read or
  drive Rocky's conversations.

It also brings risks:

- Conversation latency on Hermes-owned turns includes process IPC + a
  cloud LLM round trip in the common case (most of Hermes' shipped
  providers are cloud-hosted).
- Two memory systems racing.
- A Python agent loop that may issue tool calls Rocky's runtime layer
  doesn't know about.
- Distribution: Hermes' install is a curl-pipe-bash; not aligned with
  the current uv-managed sidecar venv hygiene.

## Options considered

The brief enumerates five. Recapping each, then the recommendation.

### Option A — Rocky-as-MCP-server, Hermes-as-brain

Rocky exposes its capabilities (`look_at`, `play_emotion`, `say`,
`stop_speaking`, `set_motor_mode`, `wake_up`, `go_to_sleep`,
`get_state`, `pause/resume_face_tracking`, `read_calendar`,
`get_weather`, `search_web`, `remember`, `get_current_time`) as a
**stdio MCP server**. The `hermes` process connects to that server as
a tool provider. Voice/STT/TTS still live in Rocky; transcripts pipe
to Hermes; replies flow back. `CognitionEngine` and `LMStudioClient`
become optional.

**Pros**

- Cleanest separation: Hermes owns cognition, Rocky owns embodiment.
- Reuses the entire Hermes stack — gateways, skills, memory, scheduler,
  bidirectional MCP — with no glue.
- One LLM at a time, one ToolRegistry at a time. Robot safety is intact:
  whichever brain holds the floor calls the tools.
- Future-proof — anything the Hermes ecosystem adds, Rocky inherits.

**Cons**

- Voice latency. The default Hermes model is a cloud LLM; first-token
  through Hermes will be limited by the user's network + the chosen
  provider. With `--model openai/gpt-4o-mini` we are at 600-1200 ms
  to first token over a stable broadband; with a slow link we exceed
  the 1.5 s target.
- Hermes' install (`curl … install.sh | bash`) breaks the sidecar
  hygiene unless we wrap it.
- Hermes thinks of itself as the top-level UI — its CLI / gateways /
  prompts assume `~/.hermes/` is theirs. We have to ensure that
  doesn't leak into Rocky's persona.
- mempalace becomes redundant; Honcho is now authoritative.
- `~/.hermes/` is a global directory; if the user runs Hermes for
  other purposes (Claude Desktop), a single Hermes install conflates
  Rocky's session with everything else.

### Option B — Hermes-as-sidecar replacing LMStudioClient

Hermes runs as a Rocky sidecar via `SidecarHost`. Rocky's
`LMStudioClient` is replaced (or joined) by a `HermesClient` that
streams user input to the Hermes process and receives streaming
responses. ToolRegistry tools are exposed via a small RPC layer
Hermes calls. Rocky's persona, voice, tools all stay where they are.

**Pros**

- Honours the sidecar invariant — Hermes lives behind a manifest, gets
  free supervision/restart/circuit-breaker.
- `LMStudioClient` and `HermesClient` can coexist behind a `BrainClient`
  protocol; the user picks per-conversation.
- Rocky's persona stays intact; we drive Hermes from a system prompt
  the same way we drive LM Studio.

**Cons**

- We have to teach Hermes how to call Rocky's tools. Hermes has its
  own tool schema; reproducing every Rocky tool there is N×M work and
  drifts every time the registry changes.
- Hermes' wire is its own — a CLI-shaped agent, not a chat-completions
  endpoint. Streaming bytes through `SidecarHost` is doable, but the
  `(content delta, tool_call delta)` shape `CognitionEngine` expects
  is not what Hermes emits.
- We lose Hermes' best feature: the gateways. Telegram input still
  has to come back through Rocky.
- Dual memory: mempalace inside Rocky, Honcho inside Hermes. Without a
  bridge, recall from one is invisible to the other.

### Option C — Hermes as an alternative provider in `LMStudioClient`

Hermes already exposes an OpenAI-compatible API surface via `hermes
serve` (when configured); treat it as just another provider. Settings
→ Brain offers "LM Studio" or "Hermes" as the provider URL.

**Pros**

- Cheapest to implement — change a base URL, change a model name, done.
- Zero new code paths.

**Cons**

- This option only works if Hermes' `serve` mode is a true OpenAI
  chat-completions server with `tool_calls` deltas. As of the public
  README it isn't — Hermes is an *agent*, not a model gateway. Its
  HTTP API is task-shaped, not turn-shaped.
- We get none of the Hermes value (gateways, skills, scheduled cron,
  Honcho memory) — those are CLI-mode features.
- Effectively this is "use OpenRouter / OpenAI directly," with Hermes
  in name only. If that's what the user wants, the simplest path is
  to point `LMStudioClient` at OpenRouter and skip Hermes.

### Option D — Hybrid: Hermes for skills/memory only, current cognition preserved

Cherry-pick `agentskills.io` skills + Honcho memory but keep the LM
Studio-driven turn loop. Skills are loaded as additional tools; Honcho
replaces or augments mempalace. The most surgical option.

**Pros**

- Preserves Rocky's voice latency (still local LM Studio + Gemma).
- Adds Hermes' best memory model (Honcho) and skills system without the
  cognition handover.
- Works with the existing tool registry — skills become tool entries.

**Cons**

- We're forking Hermes' best parts. Honcho and `agentskills.io` are
  upstream but their main consumers are inside Hermes — keeping pace
  with their upstream evolution is a small but real maintenance cost.
- We lose every feature that *needs* Hermes' agent loop: Telegram
  gateways, scheduled cron, subagent delegation, `hermes mcp serve`.
- Skills need a runtime to execute. We'd be re-implementing the
  agentskills runtime in Swift, or running it inside the mempalace
  sidecar — non-trivial either way.
- Honcho needs a Python runtime; that's another sidecar.

### Option E — Bidirectional MCP + dual-brain

Rocky-as-MCP-server (option A) **and** Rocky also consumes Hermes'
MCP server (`hermes mcp serve`) so Rocky can read Telegram / Discord
conversations the user has with Hermes. Two brains, sharing context.

**Pros**

- Maximally capable. Rocky knows what the user told Hermes via
  Telegram; Hermes knows what the user said to Rocky's mic.
- Two brains can specialise — the local Gemma stays for low-latency
  voice, Hermes handles long-form async chat from the messaging
  gateways.

**Cons**

- Robot safety: two systems can issue motion calls. The hard constraint
  rules this out unless we add an arbitrator. That arbitrator is
  non-trivial — we have to define ownership transitions, queue
  conflicts, and rollback semantics.
- Calm-tech: two conversations on one chat surface is confusing. We
  end up with "what did Hermes-Rocky say earlier?" vs. "what did
  voice-Rocky say earlier?".
- mempalace AND Honcho AND a third reconciliation layer.
- High implementation cost; this is the next two months of work.

## Decision

**Adopt Option A (Rocky-as-MCP-server, Hermes-as-brain) as the
*opt-in advanced path* while keeping the current LM Studio path as
the default first-launch experience.**

Concretely:

1. Build `Sources/MCPHost/` — a Swift implementation of the Model
   Context Protocol stdio server. It exposes the existing
   `ToolRegistry` over the MCP `tools/list` + `tools/call` surface.
   No tool reimplementation; the registry stays the canonical schema
   list (per [tools-registry.md](../concepts/tools-registry.md)).
2. Wrap Hermes in a `Sidecars/hermes/` directory under the standard
   sidecar convention. The sidecar's `setup.sh` runs the Hermes
   `install.sh` into a Rocky-scoped `~/.hermes-rocky/` so Hermes' global
   state doesn't leak into the user's other Hermes use.
3. Add a `BrainBackend` protocol in `Cognition` with two implementations:
   `LMStudioBrain` (the current `CognitionEngine` + `LMStudioClient`
   path, unchanged) and `HermesBrain` (drives the Hermes sidecar's
   chat loop via stdin/stdout).
4. Settings → Brain gets a "Backend" selector: `LM Studio (local)` |
   `Hermes (advanced)`. LM Studio stays the default. Switching backends
   is hot-reloadable just like model swaps are today.
5. Memory: when `HermesBrain` is active, mempalace recall and writes
   are **paused**, not removed. Honcho becomes authoritative for that
   session. The LogBus surfaces "memory backend: honcho" so the user
   can see why mempalace count isn't growing.
6. Robot safety: only the active backend has access to the
   `MotionMutex`. Switching backends is a fenced operation — current
   in-flight tool calls drain before the new backend gets the floor.
7. Voice: STT, wake, TTS, robot motion all stay in Rocky. Hermes
   never hears raw audio and never sees the daemon. The first-token
   latency budget is degraded **only** when the user opts into Hermes;
   if they pick a slow cloud model behind it, that's a Settings-time
   decision they can revisit.
8. Calm-tech: the cockpit's conversation panel is identical regardless
   of backend. The transcript shows "Rocky:" lines either way. A small
   subdued indicator below the model name notes "Backend: Hermes" when
   that's active. No two-pane chat, no separate inbox surface.
9. Bidirectional MCP — option E's read-the-Telegram-thread feature —
   is **deferred** to a follow-up ADR. We ship A first; E is a bonus
   that requires the arbitration layer described above and isn't on
   the critical path.

### Why A (and not B / C / D / E)

- **Not B**, because B duplicates the tool registry and loses Hermes'
  gateways. Hermes-as-replacement-LLM throws away most of what makes
  Hermes interesting.
- **Not C**, because C is "just use OpenRouter" with extra ceremony.
  If we want a cloud LLM we don't need Hermes.
- **Not D**, because D is the most code for the least Hermes value.
  Re-implementing the agentskills runtime in Swift is a project,
  not a feature.
- **Not E**, because E forces an arbitrator we haven't proven we
  need. Once A is shipped and stable, E becomes a follow-up
  conversation about whether the dual-brain UX is worth the
  motion-arbitration complexity.
- **Yes A**, because A respects every constraint: (1) sidecar
  invariant — Hermes lives behind a manifest; (2) voice latency —
  default path is unchanged; (3) robot safety — single active
  backend at a time; (4) calm-tech — same chat surface; (5) no
  abandonment — LM Studio still default; (6) Swift 6 — MCPHost
  is a normal actor + AsyncStream, like every other Rocky package;
  (7) mempalace — paused, not deleted, when Hermes is active.

### What stays, what changes, what goes

| Surface | Status |
|---|---|
| `LMStudioClient` | **Stays.** Default backend. Unchanged. |
| `CognitionEngine` (turn loop, fenced-JSON fallback, `cleanupForTTS`, `extractFencedToolCalls`) | **Stays.** Used by `LMStudioBrain`. The fenced-JSON path remains because Gemma 4 e4b is still the local default. |
| `ToolRegistry` | **Stays.** Canonical schema source. New `MCPHost` exposes the same registry over MCP. |
| `Sources/Rocky/Tools/` external tools | **Stays.** Unchanged. They register against the same registry. |
| `mempalace` sidecar | **Stays.** Authoritative on the LM Studio path; paused when Hermes is the active backend. |
| `MemoryService` | **Stays.** Adds a `setActive(_ on: Bool)` method so AppServices can pause it during a Hermes session. |
| Persona prompt (`SettingsStore.defaultPersona`) | **Stays for LM Studio, ported for Hermes.** A second persona variant (`hermesPersona`) drops the "fenced JSON" fallback section since Hermes uses native MCP. Persona migration version bumps to 6. |
| `Settings → Brain` | **Changes.** Adds a "Backend" selector. The model dropdown remains for LM Studio; for Hermes the dropdown becomes "Hermes model" via `hermes model list`. |
| Sidecar tree | **Adds** `Sidecars/hermes/`. |
| Swift packages | **Adds** `MCPHost`. Updates `Cognition` with `BrainBackend` protocol + `HermesBrain`. |
| `~/.hermes-rocky/` | **New.** Rocky-scoped Hermes home. Isolated from the user's global `~/.hermes/`. |

## Consequences

### Positive

- One tool registry, two brains. The schema list `ToolRegistry`
  publishes is the same whether Rocky exposes it via OpenAI tool_calls
  to LM Studio or via MCP `tools/call` to Hermes.
- Hermes' gateways (Telegram / Discord / Signal / Slack / WhatsApp)
  become available without writing five glue layers — the user runs
  `hermes gateway add telegram` once and the same Rocky-MCP toolset
  is reachable from their phone.
- The Hermes-as-MCP-server feature (`hermes mcp serve`) becomes
  available bidirectionally for free once we add the consumer side
  later (deferred ADR).
- `MCPHost` can be reused. Other Mac AI clients (Claude Desktop,
  Cursor, Codex) will be able to discover Rocky's tool surface
  without further work. "Make Rocky look at the door, from Cursor"
  becomes a shipped feature.

### Negative

- One more sidecar to ship. `Sidecars/hermes/` is non-trivial because
  Hermes' `install.sh` is curl-pipe-bash. We'll wrap it in a
  `setup.sh` that downloads the install script with a pinned commit
  SHA, runs it into the Rocky-scoped home, and hashes the result.
- Hermes brings a Python sub-process tree of its own — when we run
  Hermes, Hermes is forking subagents. The supervisor sees one
  PID; the actual process count under load may be 3-5.
- `MCPHost` is new code; MCP is a young protocol, the spec is still
  evolving. We accept upstream churn for the next 6-12 months.
- Hermes' default LLM provider list assumes API keys in `~/.hermes/`.
  We'll need a Settings → Brain → Hermes Providers panel that writes
  keys into `~/.hermes-rocky/` instead, surfacing them in the UI.
- The user can pick a Hermes model that breaks the voice latency
  budget. Settings → Brain → Backend: Hermes will warn ("first-token
  latency depends on your chosen Hermes model — voice may feel slow")
  and link to the mitigation (use a fast OpenRouter model, run
  `hermes model fast`).

### Neutral

- Bidirectional MCP (option E) is deferred but cheap to add later
  because the consumer side is symmetric to the server side we're
  building now.
- Distribution: the .app bundle stays the same. Hermes' install runs
  on first switch to the Hermes backend, not at app launch — like
  every other ML-extras sidecar (`mlx-tts`, `face-tracker[sam]`).

### Robot safety

The `MotionMutex` is the linchpin. It is a `MainActor`-isolated flag
on `AppServices` that gates `look_at`, `play_emotion`, `wake_up`,
`go_to_sleep`, `stop_motion`, `pause_face_tracking`,
`resume_face_tracking`, `express`. Whichever backend is active holds
the mutex; the inactive one's tool calls (which shouldn't be in
flight, but defence in depth) get a `{"ok": false, "error": "backend
not active"}` response.

The single-instance guard on Rocky already prevents two Rocky
processes from running. With one Rocky and one Hermes — and the
mutex — the robot has exactly one motion authority at any moment.

### Voice latency

The Hermes path is opt-in; the LM Studio default path is unchanged
and continues to meet the < 1.5 s first-token-to-speech target.
When the user opts into Hermes, the first-token budget becomes
"whatever Hermes' provider gives us." Settings has to make this
visible.

## Alternatives considered

Beyond options B/C/D/E above:

- **Build our own Telegram / Discord gateway in Swift** instead of
  using Hermes. Doable but each gateway is its own engineering
  project. Hermes already does this; using it is the cheaper path.
- **Use Hermes' MCP server as our cognition brain (option A
  inverted).** I.e. Rocky reads from `hermes mcp serve` directly.
  This works for chat history but Hermes' MCP server doesn't drive
  cognition — it surfaces conversations. Rejected.
- **Bypass MCP and use a custom JSON-RPC.** MCP is an emerging
  standard with growing tooling; betting on it is correct even
  given the spec churn.

## Implementation plan

See [`workflows/integrate-hermes-agent.md`](../workflows/integrate-hermes-agent.md)
for the milestone breakdown (HM1-HM6).

## See also

- [Hermes Agent (concept)](../concepts/hermes-agent.md)
- [Integrate Hermes Agent (workflow)](../workflows/integrate-hermes-agent.md)
- [Sidecar convention](../concepts/sidecar-convention.md)
- ADR [0003 — Sidecar convention](0003-sidecar-convention.md)
- [Tools registry](../concepts/tools-registry.md)
- [Voice / listen pipeline](../concepts/voice-pipeline.md)
- Hermes Agent: <https://github.com/nousresearch/hermes-agent>
- Model Context Protocol: <https://spec.modelcontextprotocol.io>
