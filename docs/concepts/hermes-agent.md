---
title: Hermes Agent
type: concept
status: proposed
last_updated: 2026-05-09
sources:
  - decisions/0004-hermes-agent-integration.md
tags: [hermes, cognition, mcp, sidecar, brain]
---

# Hermes Agent

Rocky's optional, advanced cognition backend. When enabled, Rocky's
local LLM turn loop is replaced by [Hermes
Agent](https://github.com/nousresearch/hermes-agent) — a complete
agent system from NousResearch with its own model registry,
messaging gateways, persistent memory, skills, scheduler, and MCP
servers. Rocky exposes its capabilities to Hermes over MCP; Hermes
runs as a Rocky-supervised sidecar so the rest of the app's
contracts (sidecar lifecycle, telemetry, calm-tech UX) hold.

This document describes what Hermes is, how it fits Rocky once
integrated, and what changes for users who flip the switch. The
*decision* for adopting it is in [ADR 0004](../decisions/0004-hermes-agent-integration.md);
the *plan* for shipping it is in
[`workflows/integrate-hermes-agent.md`](../workflows/integrate-hermes-agent.md).

## What Hermes is

Hermes is a Python CLI (`hermes`) that orchestrates LLM-backed
conversations with a large suite of tools and gateways. It is not a
library — you don't `import hermes`. You run `hermes` and it owns the
session.

Notable surfaces:

- **Tool registry** — 40+ built-in tools organised into "toolsets"
  (web, code, filesystem, productivity, etc.). Skills (the
  `agentskills.io` standard) extend it.
- **Memory** — Honcho dialectic user modeling with FTS5 indexed search.
  Persistent across sessions.
- **Skills** — procedural memory; markdown files describing how to
  perform a task that the agent loads when relevant.
- **Conversations** — durable history; Hermes remembers prior threads.
- **Scheduler** — cron-style; "every weekday at 09:00, ask the user
  about their plan."
- **Subagent delegation** — Hermes can spawn agents to do focused
  sub-tasks.
- **Provider-agnostic LLM** — OpenAI, OpenRouter, Hugging Face,
  Nous Portal, NVIDIA NIM, Anthropic, etc. Switch with `hermes model`.
- **Messaging gateways** — Telegram, Discord, Slack, WhatsApp, Signal.
  Run as `hermes gateway`.
- **Bidirectional MCP** —
  - `hermes mcp serve`: exposes Hermes' conversations to Claude
    Desktop / Cursor / Codex / any MCP client.
  - Hermes also consumes external MCP servers as tool sources.
- **Terminal backends** — Local, Docker, SSH, Modal, Daytona, Vercel
  Sandbox. Hermes picks where its sub-tasks execute.

A Hermes install lives in `~/.hermes/` — config, sessions, skills,
provider keys.

## How Hermes fits Rocky

Rocky exposes its tool surface to Hermes, runs Hermes under the
sidecar contract, and wires Hermes' chat loop to the same voice
pipeline (mic → STT → wake → cognition → say → TTS → robot speaker)
that already works on the LM Studio path. The user toggle is in
Settings → Brain → Backend.

```
+------------------------ Rocky.app (macOS) -------------------------+
|                                                                    |
|  Voice / listen pipeline (unchanged — see voice-pipeline.md)       |
|     mic ─▶ VAD ─▶ STT ─▶ WakeFilter ─▶ user transcript             |
|                                            │                       |
|                                            ▼                       |
|  Cognition.BrainBackend  ─────────────► one of:                    |
|     |                                                              |
|     |── LMStudioBrain   (default; CognitionEngine + LMStudioClient)|
|     |                                                              |
|     └── HermesBrain     (opt-in; chats Hermes via stdin/stdout)    |
|                                            │                       |
|                                            ▼                       |
|  ToolRegistry  ◀─── invoke (SAME REGISTRY in both paths)           |
|     ▲                                                              |
|     └─ MCPHost  ◀── mcp tools/call ◀── Hermes sidecar              |
|                                                                    |
|  SidecarSupervisor                                                 |
|     |- mempalace      (paused while Hermes is the active backend)  |
|     |- mlx-tts                                                     |
|     |- face-tracker                                                |
|     |- robot-mic                                                   |
|     \- hermes         (NEW; Hermes Agent process tree)             |
|                                                                    |
+--------------------------------------------------------------------+
```

The user always talks to "Rocky." Hermes is invisible to the user
except for a subdued backend indicator below the model name in the
cockpit.

## What runs where

| Concern | Owner |
|---|---|
| Mic / VAD / STT | Rocky (unchanged) |
| Wake-word filter | Rocky (unchanged) |
| Persona prompt | Rocky (per-backend variant; persona-version 6 ships both) |
| LLM turn loop | LM Studio path: `CognitionEngine`. Hermes path: Hermes |
| Tool schema source | `ToolRegistry` (one registry, both paths) |
| Tool dispatch (LM Studio path) | `CognitionEngine.runTurn` → `ToolRegistry.invoke` |
| Tool dispatch (Hermes path) | Hermes → MCP → `MCPHost` → `ToolRegistry.invoke` |
| Robot motion | Rocky (whichever brain holds the `MotionMutex`) |
| TTS | Rocky (`mlx-tts` sidecar — same path) |
| Memory | LM Studio path: mempalace. Hermes path: Honcho (mempalace paused) |
| Conversation history | LM Studio path: `CognitionEngine.transcript`. Hermes path: Hermes' durable sessions |
| Messaging gateways | Hermes (`hermes gateway add telegram`) |
| Scheduled cron | Hermes (`hermes schedule add ...`) |
| Provider keys | LM Studio path: `SettingsStore.lmStudioApiKey`. Hermes path: `~/.hermes-rocky/config.toml` |

## The MCP server (`MCPHost`)

Rocky-as-MCP-server is the bridge that lets Hermes call Rocky's
tools without anyone reimplementing them. Implementation outline:

- New Swift target: `MCPHost`, depending on `Cognition`.
- Implements the [Model Context Protocol](https://spec.modelcontextprotocol.io)
  stdio transport. JSON-RPC 2.0 messages on stdin/stdout.
- Surfaces:
  - `initialize` / `initialized` handshake.
  - `tools/list` — returns the schemas from `ToolRegistry.schemas`,
    re-shaped to the MCP `tool` schema (`name`, `description`,
    `inputSchema`).
  - `tools/call` — receives `(name, arguments)`, routes to
    `ToolRegistry.invoke(name:argumentsJSON:)`, returns the result.
  - `notifications/tools/list_changed` — emitted when AppServices
    re-registers tools.
- The MCP server runs **inside the Rocky process** as an actor,
  reading/writing on a pair of pipes. Hermes is the client; Hermes
  spawns Rocky-as-MCP-server via a manifest entry in `~/.hermes-rocky/mcp.toml`.
- One actor, one ToolRegistry reference. Logging through `LogBus`
  with a new `mcp_request` / `mcp_response` event class on
  `TelemetryEvent`.

The MCP surface is what makes Rocky reusable from other clients
later (Claude Desktop, Cursor, Codex) — once `MCPHost` exists, any
MCP client on the same Mac can drive Rocky.

## The Hermes sidecar

Hermes installs via curl-pipe-bash. The Rocky sidecar wraps that
into a manifest-shaped, idempotent `setup.sh`. See the workflow doc
for the exact script; the salient design points:

- Hermes' install runs into `~/.hermes-rocky/` instead of the user's
  global `~/.hermes/`. This isolates Rocky's session, prompts, and
  provider keys from the user's other Hermes uses.
- The wrapped install pins a commit SHA. The Rocky `setup.sh` records
  the SHA, downloads the matching `install.sh`, hashes it, and aborts
  if the hash doesn't match a value committed in the sidecar
  directory. We do not curl-pipe-bash arbitrary live URLs.
- The manifest's `binary` is `~/.hermes-rocky/bin/hermes`; `args`
  put it into a "headless chat" mode that reads JSON requests on
  stdin and emits JSON deltas on stdout (a thin Python `runner.py`
  in the sidecar wraps this — Hermes' CLI doesn't natively expose a
  line-delimited JSON wire, so we adapt at the sidecar boundary).
- `~/.hermes-rocky/mcp.toml` registers `Rocky` as an MCP server
  Hermes consumes; this file is generated by the sidecar's
  `setup.sh` from a template that points at `Sources/MCPHost`'s
  resolved binary path.

## The brain backend protocol

```swift
public protocol BrainBackend: Actor {
    var name: String { get }                // "lm-studio" | "hermes"
    var isActive: Bool { get async }
    func send(userText: String) -> AsyncThrowingStream<BrainOutput, Error>
    func reset() async
    func setPersona(_ prompt: String) async
}
```

`LMStudioBrain` wraps the existing `CognitionEngine` 1:1 — its
implementation forwards every call. `HermesBrain` owns the Hermes
sidecar, sends user text on the wire, and translates Hermes' deltas
back into the same `BrainOutput` shape (`assistantDelta`,
`assistantFinal`, `toolCallDispatched`, `toolCallResult`, `error`)
that `CognitionEngine.Output` already publishes. The cockpit's
conversation rendering is unchanged.

`AppServices.cognition` becomes `AppServices.brain: any BrainBackend`,
swapped at backend-change time. The swap is fenced: any in-flight
turn drains, the inactive backend releases the `MotionMutex`, then
the new backend takes over.

## Persona variants

Rocky's persona prompt rules are in
[`SettingsStore.swift:166-267`](../../Sources/Rocky/SettingsStore.swift#L166).
The LM Studio variant carries a fenced-JSON fallback section because
Gemma 4 doesn't reliably emit `tool_calls`. The Hermes variant drops
that section — Hermes' MCP path is structured, no fenced fallback
needed — but keeps every other rule (Rocky speaks in third person,
drops articles, calls `say` to talk, etc.).

The current persona migration mechanism (the
`currentPersonaVersion` static, bumped per rewrite) handles both
variants. Bumping to v6 ships both prompts and migrates installs
that have v5 stored.

## Memory

Two memory systems exist; only one is authoritative per session.

- **LM Studio path:** mempalace is authoritative.
  `CognitionEngine.fetchRecallEnvelope` injects top-K hits into each
  turn; `recordDetached` writes both sides post-turn. Unchanged.
- **Hermes path:** Honcho is authoritative. `MemoryService.setActive(false)`
  pauses mempalace recall and writes for the duration of the Hermes
  session. mempalace's stored history is preserved — flipping back
  to LM Studio later resumes recall against the original store.

The bridge between the two stores is **not** automatic. We do not
sync mempalace into Honcho or vice versa, because the two have
different schemas (mempalace stores verbatim drawers; Honcho stores
dialectic user model fragments). A future ADR may revisit if users
ask for unified history.

The Settings → Memory tab gains a backend indicator showing which
store is currently authoritative + drawer/fragment counts for each.

## Robot safety

Today the `say` tool is the longest-running tool in the registry —
it stamps `ttsBusyUntil`, awaits TTS synth + upload + play, then
clears. With two backends in the system, the gating principle is:

- The `MotionMutex` (a new `MainActor`-bound flag on `AppServices`)
  is held by exactly one backend at a time.
- Tool handlers that touch the robot — `look_at`, `play_emotion`,
  `wake_up`, `go_to_sleep`, `stop_motion`, `pause_face_tracking`,
  `resume_face_tracking`, `express`, `set_motor_mode`, `say`,
  `stop_speaking` — guard on the mutex before doing anything; if
  the calling backend doesn't hold it, return
  `{"ok": false, "error": "backend not active"}`.
- Switching backends drains in-flight tool calls before flipping
  the mutex. The cockpit shows a brief "switching brain" state
  (subdued, ≤ 2s typically).

This is in addition to the existing single-instance guard
(`RockyApp.init`), which already prevents two Rocky processes from
fighting over the robot. The mutex is the within-process
equivalent, and it gates the same set of robot-touching tools.

## Voice latency

The default LM Studio + Gemma path is unchanged. First-token-to-speech
< 1.5 s.

The Hermes path inherits whatever Hermes' active LLM provider gives
us. Realistic ranges:

- OpenRouter / Groq fast model — 600 ms-1 s first token. Inside
  budget.
- OpenAI gpt-4o-mini — 700 ms-1.5 s. Borderline.
- Anthropic Sonnet — 800 ms-2 s. Often over budget on the first
  token of a turn.
- Local Ollama — depends on hardware.

Settings → Brain → Backend: Hermes will surface a latency hint based
on the chosen Hermes model, with a link to switch to a faster model.

## What gets new telemetry

Add cases to [`TelemetryEvent`](../../Sources/Telemetry/TelemetryEvent.swift):

- `brain_backend_switched(from: String, to: String, reason: String)` —
  user-initiated or fallback.
- `mcp_request(method: String, params_summary: String)` —
  MCP server side, ToolRegistry inbound.
- `mcp_response(method: String, latencyMs: Double, ok: Bool)` —
  paired return.
- `hermes_event(kind: String, summary: String)` — Hermes-emitted
  events that surface in Rocky's logs (gateway connect, schedule
  fired, etc.). Filtered: only events that affect the user-visible
  conversation.

The closed-set rule from CLAUDE.md still applies — any new event
type goes through `TelemetryEvent` so the LogsView, Inspector, and
archive all see it from one place.

## What this does not include

- **Bidirectional MCP** (option E in the ADR): Rocky consuming
  `hermes mcp serve` to read the user's Telegram threads. Deferred.
- **Memory sync** between mempalace and Honcho. Deferred.
- **Two simultaneous brains** with arbitration. Explicitly out of
  scope; one backend is active at a time.
- **Public-cloud Hermes session sharing** with other Rocky users.
  Out of scope.

## See also

- ADR [0004 — Hermes Agent integration](../decisions/0004-hermes-agent-integration.md)
- [Integrate Hermes Agent (workflow)](../workflows/integrate-hermes-agent.md)
- [Tools registry](tools-registry.md)
- [Voice / listen pipeline](voice-pipeline.md)
- [Sidecar convention](sidecar-convention.md)
- [Rocky architecture](rocky-architecture.md)
- Hermes Agent: <https://github.com/nousresearch/hermes-agent>
- Model Context Protocol: <https://spec.modelcontextprotocol.io>
