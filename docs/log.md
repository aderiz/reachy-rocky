# Log

Append-only chronological record. Each entry: `## [YYYY-MM-DD] <op> | <subject>`. Run `grep "^## \[" log.md | tail -20` for the recent timeline.

## [2026-05-05] code | Rocky M1 — workspace + foundational packages

Plan approved (`/Users/amplifiedai/.claude/plans/i-d-like-this-to-swirling-octopus.md`). M1 first-pass scaffold landed:

- `Package.swift` defines: `Rocky` (executable), `RockyKit`, `Telemetry`, `SidecarHost`, `RobotLink` (libraries) + 3 test targets. Swift 6 mode, `.macOS(.v15)`.
- `RockyKit`: `Angle`/`Length` units, `HeadPose` (16-element row-major SE(3)), `Antennas`, `MotorMode`, `SafetyLimits`, `RobotState`/`MotionTarget` codecs that map the daemon's wire shape (`head` as flat 16, `antennas` as `[right, left]`).
- `Telemetry`: `LogBus` actor (multicast `AsyncStream` subscription) and the closed `TelemetryEvent` taxonomy from plan §4.6.
- `SidecarHost` skeleton: `SidecarManifest` (JSON, `{venv}`/`{sidecar_dir}` placeholders), `Sidecar` protocol, `SidecarState`/`SidecarError`, `JSONLineCodec` (handles `response` / `error` / `stream` / `stream_end` / `event` / `log` envelopes; partial-line buffering), `SidecarSupervisor` registry. Real `SidecarRuntime` (Process/pipes/restart loop) lands in M2.
- `RobotLink`: `RobotLinkClient` actor (REST: `daemon/status`, `state/full`, `move/set_target`, `move/goto`, `move/stop`, `move/play/{wake_up,goto_sleep}`, `motors/set_mode/{mode}`); `TargetStreamer` actor (50 Hz tick, single producer/single consumer, pauses while `is_move_running`).
- `Rocky` app target: SwiftUI `WindowGroup` + `MenuBarExtra` shell, `AppServices @Observable`, placeholder dashboard / sidebar / hero card / connection badge.
- 12 Swift Testing tests across pose math, safety clamps, daemon-state decoding, endpoint URL composition, and JSON-line codec round-trips. All green.

Open M1 work: live `/openapi.json` validation against the actual robot, `HealthChecker` periodic poll, WebSocket state subscriber, motion-card visualization. Will land in subsequent commits before moving to M2.

## [2026-05-05] code | Rocky M2 — SidecarHost end-to-end

Implemented the user-mandated Sidecar contract end-to-end:

- `SidecarRuntime` actor: spawns a `Process`, owns three pipes, dispatches stdout envelopes through `JSONLineCodec`, drains stderr as logs, correlates `id`-keyed responses, supports stream methods, applies per-method timeouts via `withThrowingTaskGroup`, surfaces unsolicited events through an `AsyncStream`.
- `SidecarSupervisor`: registers a manifest as a runtime, watches each runtime's events stream, detects `.failing` and applies `restartPolicy` with per-minute circuit breaker (`restart_max_per_minute`).
- `FirstRunSetup`: idempotent installer that runs `setup.sh` only when `.venv/bin/python` is missing.
- `Sidecars/echo/`: stdlib-only Python proof-of-contract sidecar (echo, add, slow, fail, stream_count, crash). Manifest pins `/usr/bin/python3` so tests don't need a venv build.
- `EchoSidecarIntegrationTests` (6 tests): basic round-trip, concurrent requests, error envelopes, stream lifecycle, slow-method timeout, **supervisor-restarts-after-crash** (kills the process via `sys.exit(7)`, asserts the supervisor brings it back to `.ready` within 3s and a follow-up `echo` succeeds).

Total tests: 18/18 green. The supervisor crash-recovery test runs in ~0.4s end-to-end on M-series.

The Sidecar contract is now real and reusable. Subsequent sidecars (face-tracker M3, mlx-tts M5) drop in as a directory + a Swift adapter layer.

Tried `curl http://reachy-mini.local:8000/openapi.json` — robot not reachable (mDNS timeout). Live REST validation deferred until robot is on. Continuing with M3 in the meantime.

## [2026-05-05] code | Rocky M3a — face tracker (Python sidecar + Vision adapter, synthetic mode)

The validated face-tracker design (memory: `project_face_tracker_design.md`) reborn under the Sidecar contract. State-driven, world-frame target, decoupled detection rate from motion smoothness — **no regression to per-frame P-control**.

Python (`Sidecars/face-tracker/`):

- `geometry.py` — `CameraIntrinsics(hfov=65, vfov=39)`; `normalized_bbox_center` + `angle_from_pixel`. Sign convention preserved: face on the LEFT (un<0) → +yaw (head turns LEFT), face on BOTTOM (vn>0) → +pitch (head DOWN).
- `filters.py` — `EMA(alpha=0.5)` and `CriticalDamper(omega=3 rad/s)` second-order semi-implicit Euler.
- `controller.py` — `FaceTrackerController` ingests `Detection` events, EMA-smooths the world-frame target (current commanded yaw/pitch + camera-frame offset), 50 Hz tick advances dampers; idle decay toward (0,0) after 1.5 s of no detections.
- `detector_synthetic.py` — Lissajous-traced "face" with periodic dropout windows so we exercise decay-to-home offline.
- `runner.py` — JSON-line entry point. Two threads: detector ~10 Hz emits `detection` events, command 50 Hz emits `target` events. Methods: `set_enabled`, `set_prompt`, `update_commanded_pose`, `health`, `shutdown`. Real SAM 3.1 mode (M3b) is stubbed to synthetic for now.
- Sanity-checked the Python math directly: damper converges to 0.98 of target after 2 s, controller emits +yaw for face-on-left, sign conventions hold.

Swift (`Sources/Vision/`):

- `FaceTrackerService` actor — owns the sidecar, parses `target` and `detection` events, exposes `AsyncStream<Target>` and `AsyncStream<Detection>`. Forwards `setEnabled`/`setPrompt`/`updateCommandedPose` to the sidecar.
- `FaceTargetBridge` actor — turns `Target` (yaw/pitch radians) into `MotionTarget(head: HeadPose)` and pushes into `TargetStreamer`. Pre-clamps to safety limits. Has a `setSuppressed(_)` knob so primary recorded moves win.

Tests (5 new, 23/23 total):

- `FaceTrackerSidecarIntegrationTests` (3): ready+targets at 50 Hz, `set_enabled false` round-trip, `health` round-trip.
- `VisionTests/FaceTrackerServiceTests` (2): the typed adapter bridges both streams; control methods succeed.

M3b (real SAM 3.1 + Reachy SDK camera) opens when the user is at the robot.

## [2026-05-05] init | Wiki bootstrapped from doc pass

Documentation pass on Reachy Mini Wireless. Wiki structure created in `docs/`; project-root `CLAUDE.md` points here.

Ingested:

- HF docs (`huggingface.co/docs/reachy_mini`): index, `platforms/reachy_mini/{get_started,hardware,development_workflow}`, `SDK/{quickstart,python-sdk,core-concept,apps,integration,media-architecture,installation}`, `troubleshooting`, `sdk-tutorials`.
- `AGENTS.md` (canonical agent guide, repo root).
- Skills: `motion-philosophy.md`, `control-loops.md`.
- Examples: `look_at_image.py` (full source); examples folder listing only for the rest.

Pages created:

- Schema: `CLAUDE.md` (project root), `docs/{README,WIKI,index,log}.md`.
- Concepts: `architecture`, `motion-philosophy`, `coordinate-frames`, `safety-limits`, `media-architecture`, `app-lifecycle`.
- Reference: `hardware`, `sdk-python`, `motors`, `glossary`.
- Workflows: `dev-loop-wireless`, `create-app`, `run-and-debug`.
- Patterns: `control-loop`, `recorded-moves`, `direct-hardware`.
- Sources: `agents-md`, `hf-docs`.
- Decisions: `0001-target-platform`.

Open gaps recorded in `index.md`:

- Most `skills/` files (symbolic-motion, interaction-patterns, ai-integration, safe-torque, debugging, testing-apps, rest-api, setup-environment, deep-dive-docs, full create-app).
- Most example sources (only `look_at_image.py` ingested in full).
- JS SDK page.
- Tutorial notebooks 0 + 1.
- Live daemon OpenAPI schema.
- `media_advanced_controls`, `motors_diagnosis`.

No code written yet. Project directory still empty other than `.claude/` and the wiki.
