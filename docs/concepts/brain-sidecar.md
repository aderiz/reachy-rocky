---
title: Brain sidecar (MLX-VLM)
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sidecars/brain/rocky_brain/runner.py
  - Sources/Cognition/MLXVLMBrain.swift
  - Sources/Cognition/CognitionEngine.swift
tags: [brain, mlx-vlm, cognition, gemma, qwen, tool-calling]
---

# Brain sidecar (MLX-VLM)

The native-MLX brain that produces every assistant reply when
`settings.brainBackend` is `mlx-vlm` (or `auto` with the venv
installed). It's a `mlx-vlm` 0.5.0 wrapper that takes the
`ReachyMini` chat shape, runs streaming generation with tool
extraction, and emits delta + tool-call events back to the Mac
side. See ADR
[0005](../decisions/0005-brain-backend-protocol.md) for the
swappable-backend rationale; this page covers the sidecar's
internals.

## Models

Drives whichever Hugging Face model `settings.brainModel` points at
through `mlx-vlm.load(...)`. Default
`mlx-community/Qwen3-VL-4B-Instruct-4bit` (~2.5 GB, vision-aware).
Other curated options live in `Sources/Rocky/SettingsView.swift`
under `BrainSettingsTab.mlxModelOptions`:

- `Qwen3-VL-4B-Instruct-4bit` — default, ~2.5 GB.
- `Qwen3-VL-30B-A3B-Instruct-4bit` — ~17 GB.
- `Qwen3-VL-30B-A3B-Instruct-8bit` — ~30 GB.
- `Qwen3-VL-235B-A22B-Instruct-4bit` — ~120 GB, Studio Ultra.

Gemma 4 26B-A4B works too via the same sidecar (and was the v0.2
default until the Qwen3-VL family proved better at tool-calling).

## RPC surface

`runner.py:547-563` exposes:

| Method | Purpose |
|---|---|
| `health()` | Liveness + the currently-loaded model id. |
| `set_model(model_id)` | Hot-swap the loaded model. Re-loads weights; can take 30–60 s for a 4B model from cold cache. |
| `chat_stream(messages, tools)` | Streaming chat completion. Returns a sequence of events (see below). |

`chat_stream` is the only path Rocky uses in practice. Returns:

```
{event: "delta", text: "..."}         # per content token
{event: "tool_call", call: {...}}     # one event per parsed call
{event: "stream_end"}                 # final
```

The `tool_call` payload is normalised to `{id, type, function:
{name, arguments}}` regardless of which extraction path produced
it (see below).

## Tool-call extraction

The brain has to recognise tool calls in two different formats,
because models emit them differently and the same model can switch
formats per-prompt.

**Gemma 4 — `<|tool_call> ... <tool_call|>` markers.** Captured
inline during streaming. The `StreamFilter` class
(`runner.py:113`) suppresses bytes between the markers token-by-
token so they don't leak into the visible delta stream. Each block
is parsed via mlx-vlm's native `gemma4` tool parser
(`mlx_vlm.tool_parsers.gemma4.parse_tool_call`) which knows the
exact internal format. If the parser is unavailable (old mlx-vlm
version), the runner falls through to the regex path below.

**Qwen / OpenAI-style — fenced JSON.** A trailing regex
(`runner.py:79`) catches `<tool_call>{...}</tool_call>` shapes
that some non-Gemma models emit. This is also the fallback for
brain output where the StreamFilter saw nothing (e.g. the model
emitted JSON in a markdown fence without the canonical markers).

`CognitionEngine.extractFencedToolCalls` on the Mac side runs the
same regex post-stream on the bubble text — same logic, two
locations — because non-MLX backends (LM Studio) don't pass
through the sidecar at all. If both paths fire, the dedup gate in
the engine drops the duplicate.

**`stripFencedJSONBlocks`** then cleans the JSON out of the
displayed transcript so the user doesn't see raw `{name: "say",
args: ...}` blocks alongside the spoken reply.

## Image provider — vision wiring

When `services.visionEnabled` is true, `CognitionEngine` passes a
`imageProvider` closure to the sidecar at the start of each turn.
The closure returns the latest JPEG bytes from
`services.lastCameraFrame`. The sidecar Base64-encodes it as a
`data:image/jpeg;base64,...` URI and includes it as an image part
in the user message. The vision-capable model processes it
alongside the text and can answer "what am I holding?" type
questions.

Gating:

- `visionEnabled == false` → no image attached, text-only.
- Brain backend isn't vision-capable (e.g. LM Studio with a
  text-only model) → closure isn't called.
- `lastCameraFrame == nil` → closure returns nil; turn proceeds
  text-only.

The persona (v6+) carries a VISION section with worked examples so
the model actually uses the frame instead of falling back to
"Rocky not know".

## KV + vision cache

The sidecar maintains a prompt-cache state across turns within a
conversation, plus a small vision cache keyed by image hash. Sizes
are set via the manifest environment variables:

| Var | Default | Effect |
|---|---|---|
| `ROCKY_BRAIN_VISION_CACHE_SIZE` | `8` | Number of recent JPEGs kept; same image across turns hits cache. |
| `ROCKY_BRAIN_KV_CACHE_REUSE` | `true` | When true, reuses KV-cache prefix between turns whose system prompt + tool list are unchanged. |

The KV reuse is what makes Rocky's follow-up turns much faster
than the first turn — the initial prompt + tool definitions don't
need to be re-encoded each time.

## Failure modes + diagnostics

- **mlx-vlm version mismatch.** The Gemma parser path requires
  `mlx-vlm >= 0.5.0` (with the singular `parse_tool_call`
  function). Older versions had `parse_tool_calls` (plural) and
  the runner's `get_tool_markers` returns hard-coded defaults if
  the import fails.
- **Empty stream / zero tokens.** Earlier debugging found this
  could happen on a malformed image part. The runner retries the
  turn without the image attached and logs to stderr; see commit
  `91a9172`.
- **Stderr diagnostics surface in the Mac sidecar log.**
  `SidecarHost` mirrors sidecar stderr to the parent process's
  stderr so they appear in Console.app under the Rocky bundle
  ID — used heavily during the v0.2 brain rebuild.

## Selecting a different brain backend

`settings.brainBackend` picks:

- `"mlx-vlm"` — this sidecar.
- `"lm-studio"` — `LMStudioBrain`, HTTP to local LM Studio.
- `"auto"` (default) — MLX-VLM if its venv is present and the
  model loads, else LM Studio.

`AppServices.applyBrainBackend()` swaps the active `BrainBackend`
at runtime; existing in-flight turns finish on the previous
backend, new ones use the new one.

## See also

- ADR [0005 — Brain backend protocol](../decisions/0005-brain-backend-protocol.md).
- [Tools registry](tools-registry.md) — where the tool schemas
  the brain sees are defined.
- [Memory](memory.md) — what gets injected into the system
  message via auto-recall.
- [Sidecar convention](sidecar-convention.md) — wire protocol
  the brain sidecar follows.
