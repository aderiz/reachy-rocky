---
title: Sidecar convention
type: concept
status: current
last_updated: 2026-05-05
sources:
  - decisions/0003-sidecar-convention.md
tags: [sidecar, ipc, swift, python]
---

# Sidecar convention

The user-mandated rule: every external process Rocky spawns runs under one
protocol, one manifest, one wire format, one supervisor. Swift never
`Process.run`s ad-hoc — it always goes through `SidecarHost`.

## Why

- Add a new sidecar = drop a directory + a few Swift adapter lines. Lifecycle is free.
- One place to debug Python crashes, hangs, slow starts.
- `kill -9` on any sidecar surfaces in the UI within milliseconds; recovery is automatic with backoff + circuit breaker.
- Distribution becomes uniform: ship the source, run `setup.sh` on first launch.

## Layers

```
~/Library/Application Support/Rocky/sidecars/<name>/.venv/   (uv-managed)
                                                  /Models/   (cache)

Sidecars/<name>/
   manifest.json        (JSON; placeholders: {venv}, {sidecar_dir})
   pyproject.toml       (uv-managed deps)
   uv.lock              (pinned)
   setup.sh             (idempotent: uv venv + uv pip install)
   rocky_<name>/
      runner.py         (entry; line-delimited JSON over stdin/stdout)
      ...

Sources/SidecarHost/
   SidecarManifest.swift     (Codable; ManifestPathResolver)
   Sidecar.swift             (protocol + SidecarOutboundEvent)
   SidecarState.swift        (state machine + errors)
   JSONLineCodec.swift       (envelope decoder; partial-line buffered)
   SidecarRuntime.swift      (Process owner; pipes; correlation table)
   SidecarSupervisor.swift   (registry; restart policy; circuit breaker)
   FirstRunSetup.swift       (idempotent setup.sh runner)
```

## Wire protocol — line-delimited JSON

stdin: requests in. stdout: responses, events, structured logs out. stderr: captured raw, tagged in the LogBus.

```
# Swift -> sidecar
{"id":"01HX...","method":"synthesize","params":{"text":"hi","voice_ref_id":"v1"}}

# sidecar -> Swift
{"id":"01HX...","result":{...}}                           # final
{"id":"01HX...","error":{"code":42,"message":"..."}}      # error
{"id":"01HX...","stream":{"chunk_index":0,"data":"..."}}  # streamed item
{"id":"01HX...","stream_end":true}                        # stream terminator

# unsolicited (no id)
{"event":"target","payload":{"yaw_rad":..,"pitch_rad":..}}
{"log":{"level":"info","ts":"...","msg":"...","fields":{...}}}
```

Rules:

- All requests must be answered (final `result` / `error` or `stream_end`).
- Events have **no** `id`.
- Log lines never carry `id` and never count as a response.
- Sidecars must flush after every line. Python: `print(json.dumps(...), flush=True)`.

## Manifest

```json
{
  "name": "mlx-tts",
  "version": "0.1.0",
  "binary": "{venv}/bin/python",
  "args": ["-u", "-m", "rocky_tts.runner"],
  "working_dir": "{sidecar_dir}",
  "env": { "ROCKY_TTS_BACKEND": "say" },
  "ready_event": "ready",
  "ready_timeout_s": 30,
  "shutdown_grace_s": 3,
  "restart_policy": "on_failure",
  "restart_max_per_minute": 3,
  "timeouts": { "*": 5, "synthesize": 30 }
}
```

`ManifestPathResolver` substitutes `{venv}` and `{sidecar_dir}` at launch. Restart policy is `never | on_failure | always`. The supervisor's circuit breaker engages when restart attempts exceed `restart_max_per_minute`.

## Lifecycle

```
.stopped --start()--> .starting -- (ready event) --> .ready
                                  \-- timeout/error --> .failing(reason) --> (supervisor restart)

.failing -- repeated rapid failures --> .circuitOpen(cooldownUntil)
```

`SidecarRuntime.send(method:params:)` correlates the request `id` against a `[id: continuation]` table; the `JSONLineCodec` dispatches incoming envelopes back to the right continuation. Streams use `AsyncThrowingStream` and end on a matching `stream_end`.

## Sidecars in the tree

| Sidecar | Methods | Backends |
|---|---|---|
| `Sidecars/face-tracker/` | `set_enabled`, `set_prompt`, `update_commanded_pose`, `health` | `synthetic` only (Lissajous test pattern, stdlib). `sam` mode + `[sam]` extras are unimplemented stubs (`runner.py:92-94`); the runner falls through to synthetic. Real face tracking is Swift-side in `Sources/Perception/MacFaceTracker.swift`. |
| `Sidecars/robot-camera/` | `start`, `stop`, `health`; emits `frame` JPEG events | `reachy_mini` SDK over WebRTC. Frames feed `MacFaceTracker`. |
| `Sidecars/robot-mic/` | `start`, `stop`, `health`; emits PCM frames | `reachy_mini` SDK over WebRTC, 4-mic ReSpeaker array. |
| `Sidecars/mlx-tts/` | `synthesize`, `set_voice_ref`, `health`, `warm_up` | `say` (default; macOS bundled TTS) ↔ `chatterbox` (`[mlx]` extras + voice ref; FP16 via `mlx-audio`). |
| `Sidecars/mempalace/` | `recall`, `record`, `health` | local memory store. |

The `echo` sidecar at `Sidecars/echo/` exists only as a contract-conformance test (`Tests/SidecarHostTests/EchoSidecarIntegrationTests.swift`).

## See also

- [Rocky architecture](rocky-architecture.md)
- [App lifecycle](app-lifecycle.md)
- ADR [0003 — Sidecar convention](../decisions/0003-sidecar-convention.md)
