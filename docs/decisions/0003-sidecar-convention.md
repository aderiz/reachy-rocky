---
title: "ADR 0003 — Sidecar convention for external processes"
type: decision
status: accepted
last_updated: 2026-05-05
tags: [decision, sidecar, ipc]
---

# ADR 0003 — Sidecar convention for external processes

## Date

2026-05-05.

## Context

Rocky needs to run multiple external processes. The original plan
called out SAM 3.1 face tracking and F5-TTS-MLX as the canonical
examples; in practice the shipped sidecars are TTS (Chatterbox FP16
via `mlx-audio`), the WebRTC audio/video bridges to the robot
(`robot-mic`, `robot-camera`), the local memory store (`mempalace`),
and a synthetic-target test scaffold for the face-tracker. The
rationale stands regardless of which detector lives where: each is
Python-based, may need MLX or other heavy dependencies, and must
integrate cleanly with Swift's structured concurrency model.

The user specified explicitly: every wrapped process must follow the **same**
convention so Swift calls them identically. No ad-hoc `Process.run`. No
per-sidecar bespoke IPC.

## Decision

Adopt a single contract — manifest + line-delimited JSON wire protocol +
supervisor — implemented in the `SidecarHost` Swift package and documented
in [`concepts/sidecar-convention.md`](../concepts/sidecar-convention.md).

Key decisions:

- **Manifest format: JSON.** Considered TOML, but Swift's stdlib doesn't
  parse TOML; JSON keeps zero external deps. Documented in the manifest as a
  `manifest.json` per sidecar.
- **Wire format: line-delimited JSON.** Trivial in Python (`print(json.dumps(...), flush=True)`) and Swift (`JSONLineCodec`). No length-prefix framing, no protobuf, no msgpack — debuggability beats compactness here.
- **Streaming: `stream` envelopes terminated by `stream_end`.** Lets a single sidecar method emit multiple chunks without per-method protocols. TTS uses this (synth chunks). Echo's `stream_count` proves it works.
- **Supervisor restart policy: per-manifest (`never | on_failure | always`)** with a `restart_max_per_minute` circuit breaker. Production code wants `on_failure`; tests use it; UI surfaces the cooldown when the breaker engages.
- **Setup script: `setup.sh` per sidecar.** Idempotent. Creates `~/Library/Application Support/Rocky/sidecars/<name>/.venv/` via `uv` and installs from the sidecar's `pyproject.toml`. `FirstRunSetup` runs it only when the venv is missing.
- **Path placeholders: `{venv}` and `{sidecar_dir}`** in the manifest's `binary`, `args`, `working_dir`. `ManifestPathResolver` substitutes at launch.

## Consequences

- A new sidecar is a 4-file drop: `manifest.json`, `pyproject.toml`,
  `setup.sh`, `runner.py`. Plus a thin Swift adapter that calls
  `runtime.send(method:params:)` for typed method calls.
- Crash recovery is uniform across sidecars and tested via the `echo`
  contract-conformance suite (`SIGKILL` mid-stream → supervisor restart →
  follow-up call succeeds within ~3 s).
- Backpressure / queueing is the caller's problem (we don't buffer messages
  while a sidecar is restarting); this is fine because every consumer holds
  its own state and re-issues on next attempt.
- Distribution: ship Sidecars/* directories alongside the .app and let
  setup.sh fire on first launch. No special installer.
- Future agents that build new sidecars should always start from the echo
  sidecar (Sidecars/echo/) as a working template.

## Alternatives considered

- **gRPC over Unix sockets.** Strong typing, well-tooled, but heavy
  dependencies, harder to debug, and Python codegen is annoying. Overkill
  for our needs.
- **MessagePack-RPC.** More compact than JSON but no native Swift / Python
  stdlib support. Negligible bandwidth wins here (≤ ~50 KB/s steady state).
- **Single-process Python via PythonKit.** Would couple Swift's
  concurrency to a single Python interpreter, making crash recovery and
  per-sidecar venvs basically impossible. Rejected.
- **`mlx-swift` for everything.** Genuinely interesting; can run small
  models in-process. But MLX-Swift's coverage of the model families we
  need (Chatterbox / Whisper / SAM-class detectors, etc.) was unverified
  at the time, and even if it worked we'd lose process-level isolation.
  Will revisit per-feature once `mlx-swift` matures. (As of 2026-05, the
  one ML model that actually moved into Swift in-process was Apple
  Vision face detection — but that's the system framework, not MLX.)

## See also

- [Sidecar convention](../concepts/sidecar-convention.md)
- [Rocky architecture](../concepts/rocky-architecture.md)
- ADR [0002 — Rocky app](0002-rocky-app.md)
