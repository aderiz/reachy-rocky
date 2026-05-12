---
title: State subscription — daemon WebSocket pump
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/RobotLink/StateSubscriber.swift
  - Sources/RobotLink/TargetStreamer.swift
  - docs/sources/daemon-openapi-1.7.1.md
tags: [robot-state, websocket, daemon, reconnect, target-streamer]
---

# State subscription

How Rocky knows what the bot is doing in real time + how it pushes
50 Hz motor targets back. Two actors that wrap the daemon's
WebSocket surface:

| Actor | File | Role |
|---|---|---|
| `StateSubscriber` | `Sources/RobotLink/StateSubscriber.swift` | Inbound — subscribes to `WS /api/state/ws/full`, emits `RobotState` ~10 Hz. |
| `TargetStreamer` | `Sources/RobotLink/TargetStreamer.swift` | Outbound — coalesces face-tracker + motion-control updates and sends `set_target` to the daemon at 50 Hz. |

## `StateSubscriber`

`StateSubscriber.swift:8` — a `public actor` consuming the state
WebSocket.

**Important quirk: the state WS is not in the daemon's OpenAPI
schema.** `/openapi.json` doesn't list it; you have to know it
exists. Endpoint:

```
ws://reachy-mini.local:8000/api/state/ws/full
```

`fullStateQuery` URL parameters (`StateSubscriber.swift:43-64`)
specify which fields to include — `WITH_HEAD_POSE=1`,
`WITH_BODY_YAW=1`, `WITH_ANTENNAS_POSITION=1`, etc. The query is
required; otherwise the daemon emits a minimal envelope without
the fields Rocky needs.

### Stream surface

```swift
public nonisolated let states: AsyncStream<RobotState>
```

`states` is buffered `.bufferingNewest(64)` — under normal load
the consumer keeps up; if the consumer is behind, we drop oldest
state updates (because the most recent state is the most useful).

`AppServices` pumps `states` and mirrors the latest into
`lastRobotState` (on MainActor) every tick. Other subsystems
(MotionCard, the avatar 3D pose) read from `lastRobotState`.

### Reconnect policy

`StateSubscriber.swift:53+` — exponential-ish backoff:
1 s → 2 s → 5 s → 10 s → 10 s …

The supervisor runs on a background task; on disconnection it
sleeps and reconnects. `status` exposes the current state
(`.stopped`, `.connecting`, `.open(...)`, `.failing(...)`).

The reconnect counter resets on a successful connection.
Cancellation-aware: if the task is cancelled (e.g. AppServices
shutting down) the loop exits cleanly.

### `RobotState` decoding gotchas

The daemon's payload has a few quirks the decoder handles:

- `control_mode` (NOT `motor_mode`) — string enum
  `disabled / gravity_compensation / enabled`.
- `head_pose` — **RPY object**, not a 16-element matrix.
- `antennas_position` (NOT `antennas`) — list of 2 doubles
  `[right, left]`.
- `is_move_running` — **not** in `state/full`; derive from
  `/api/move/running` being non-empty (a separate REST poll).

These are all documented in CLAUDE.md's "Robot wire-shape gotchas"
section + in `docs/sources/daemon-openapi-1.7.1.md`. Always cross-
reference the live OpenAPI snapshot before changing a wire-shape
assumption.

## `TargetStreamer`

`TargetStreamer.swift` — outbound 50 Hz set_target stream. Owns
the merged target snapshot produced by:

1. `MacFaceTracker` (face-driven head + body yaw at 50 Hz).
2. Antenna twitch generator (same loop, independent Poisson
   triggers).
3. Anyone else who calls `update(_:source:)` — e.g.
   `MicCalibrationView` for the deliberate motor-noise sweep.

The streamer's 50 Hz tick reads `latest` and POSTs to
`/api/move/set_target`. Source of truth is the most-recent
`update` call.

### `setPrimaryMoveActive` — suppression gate

When a primary recorded move is in flight (wake-up, sleep, an
explicit `goto`), the 50 Hz stream **must not** push competing
targets, or it'll fight the minjerk interpolation. The streamer
exposes:

```swift
public func setPrimaryMoveActive(_ active: Bool)
```

While `active` is true, the 50 Hz tick skips its `set_target`
POST. `AppServices` calls this from `wakeRobot()` / `sleepRobot()`
and from any deliberate calibration motion sequence.

### `transitioningUntil` — derived gate

`AppServices.transitioningUntil: Date?` is a higher-level shim:
when set to a future date, a watcher loop calls
`setPrimaryMoveActive(true)` until the date passes, then
`setPrimaryMoveActive(false)`. Convenience for "suppress for 3.2 s
during wake".

Calibration's motor phase additionally calls
`services.targetStreamer.setPrimaryMoveActive(true)` directly +
disables face tracking + sets `transitioningUntil` — three layers
of suppression — so nothing can steal motor attention during the
Lissajous sweep.

### Wire shape (important)

`POST /api/move/set_target` body uses **`target_*` prefixed
keys**: `target_head_pose`, `target_antennas`, `target_body_yaw`.

`POST /api/move/goto` (one-shot, blocking, used for wake/sleep
animations) uses **bare keys**: `head_pose`, `antennas`,
`body_yaw`, `duration`, `interpolation`.

Forget this and the daemon silently rejects the body. CLAUDE.md
calls this out, but a developer can easily miss it because both
endpoints take similar-looking payloads.

## See also

- [App Services](app-services.md) — owns both actors, pumps
  `states` into the observable surface.
- [Sidecar supervisor](sidecar-supervisor.md) — same restart +
  backoff philosophy, different transport.
- [Daemon OpenAPI v1.7.1](../sources/daemon-openapi-1.7.1.md) —
  the live wire shape capture. Re-snapshot when the daemon ships
  a new version.
- [Voice / listen pipeline](voice-pipeline.md) — calibration's
  three-layer streamer suppression is a worked example of the
  `transitioningUntil` + `setPrimaryMoveActive` +
  `setFaceTrackingEnabled(false)` pattern.
