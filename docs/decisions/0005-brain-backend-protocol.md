---
title: "ADR 0005 — Brain backend as a protocol, MLX-VLM as the default"
type: decision
status: accepted
last_updated: 2026-05-11
tags: [decision, cognition, vision, mlx]
---

# ADR 0005 — Brain backend as a protocol, MLX-VLM as the default

## Date

2026-05-11.

## Context

In v0.1 the cognition engine spoke directly to LM Studio over its
OpenAI-compatible HTTP surface. That gave us conversation +
tool-calling for free, but it locked the brain to one process boundary
+ one transport + one model family. Specifically:

- HTTP adds a per-token serialisation hop that shows up in the
  first-chunk latency profile.
- LM Studio's OpenAI surface doesn't carry vision payloads
  consistently across the model zoo we target (Gemma 4, Qwen 3.5,
  Phi-4 each use different conventions).
- Small models (Gemma 4 e4b) frequently fail to emit `tool_calls`
  natively and require a fenced-JSON recovery path.

The v0.2 plan called for native MLX inference with vision. Implemented
behind a `BrainBackend` protocol so the engine doesn't know which
backend is speaking. Two implementations ship today:

- `MLXVLMBrain` — wraps a Python sidecar (`Sidecars/brain/`) running
  `mlx-vlm`, loads a Qwen3-VL or Gemma 4 variant with vision.
  Streaming, native tool-call output, vision-aware. Default.
- `LMStudioBrain` — wraps the v0.1 `LMStudioClient`. Text-only
  (image arg ignored). Fallback when the brain sidecar venv is
  absent or the user explicitly forces it.

A third implementation slot is reserved for a future Hermes-style
agent (`HermesBrain`); the protocol is the seam ADR 0004 anticipates.

## Decision

```swift
public protocol BrainBackend: Sendable {
    func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema]?,
        image: BrainImage?
    ) -> AsyncThrowingStream<ChatChunk, Error>
}
```

- One method. Streams `ChatChunk` events containing token deltas
  and/or tool-call deltas.
- `image: BrainImage?` is passed every turn. Text-only backends
  ignore it; vision-aware backends inject it into the prompt at the
  most recent user message via the model's chat template
  (`apply_chat_template(..., num_images=1)`) and pass the raw bytes
  to `stream_generate(image=...)`.
- `CognitionEngine` owns an `imageProvider: (() async -> BrainImage?)?`
  closure that AppServices wires to read `lastCameraFrame`. The
  closure is consulted at turn start so each chat sees the freshest
  frame.
- The engine's `transcript` is backend-agnostic — the same
  `ChatMessage` shape works for either implementation, and tool
  results round-trip the same way.

The default brain model is `mlx-community/Qwen3-VL-4B-Instruct-4bit`
(vision-aware, fits 16 GB Macs). Users can override via
`SettingsStore.brainModel` or the `ROCKY_BRAIN_MODEL` env var; any
`mlx-vlm`-loadable HF id works. The user-facing settings backend
options are `auto` (MLX-VLM if the sidecar venv is installed, else
LM Studio), `mlx-vlm` (force MLX, error out if absent), and
`lm-studio` (force HTTP fallback).

The Status panel's "Think" capability resolves to the active backend
at render time:

- `mlx-vlm` → MLX-VLM row only (sidecar state + model short name).
- `lm-studio` → LM Studio row only (probe button + connection state).
- `auto` → MLX-VLM row when the brain sidecar is `.ready`; LM Studio
  row otherwise.

The other backend is hidden — users don't see "LM Studio offline"
warnings when Rocky is happily running on MLX.

## Consequences

Good:

- Vision works. Rocky can answer "what am I holding?" because the
  pixels travel with the text in the same prompt. Verified on both
  Qwen3-VL 4B and Gemma 4 26B-A4B (which is also a vision-language
  model — its config has `vision_config` + `image_token_id`).
- Native MLX inference removes the HTTP hop. First-chunk latency is
  governed by prefill rather than serialisation overhead.
- The fenced-JSON recovery path scopes naturally to `LMStudioBrain`.
  MLX-VLM models use the parser registered in `mlx-vlm`'s
  `tool_parsers` (Gemma 4 uses the `gemma4` parser with
  `parse_tool_call` singular form per block).
- Tests get a deterministic fake `BrainBackend` for free — no HTTP
  mocking, no Python venv.

Bad / trade-offs:

- The brain sidecar adds ~3.5 GB of disk + ~3 GB of runtime memory.
  Setup is the per-sidecar `./Sidecars/brain/setup.sh` (uv venv +
  weights download). Failure-mode-by-design: AppServices treats the
  sidecar's failure to start as "fall back to LM Studio" rather than
  blocking the app entirely.
- ICL prefill adds ~2-3 s to the first turn after a sidecar restart
  on Qwen3-VL because the vision encoder warm-runs the first image.
  Subsequent turns reuse the encoded prefill via
  `VisionFeatureCache` + `PromptCacheState`. Both are per-instance
  on the Brain in `Sidecars/brain/rocky_brain/runner.py`.
- Auto-mode resolution happens at render time for the Status panel,
  so a backend that flickers ready/not-ready will flicker which row
  shows. In practice the sidecar state changes are coarse enough
  (mostly `.ready` once warmed) that this isn't visible.

## See also

- `concepts/rocky-architecture.md` — the v0.2 block diagram showing
  `BrainBackend` between `CognitionEngine` and the sidecars.
- `concepts/voice-pipeline.md` — how the vision toolbar toggle gates
  the `imageProvider`.
- ADR `0003-sidecar-convention.md` — sidecar lifecycle, which the
  brain sidecar inherits.
- `~/.claude/plans/i-d-like-this-to-swirling-octopus.md` — the v0.2
  rebuild plan that called this out as M5. The plan reserves a third
  `HermesBrain` implementation slot for future agent-shaped routing
  on top of the same `BrainBackend` protocol.
