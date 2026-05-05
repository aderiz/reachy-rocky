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

## [2026-05-05] code | Live daemon validation + wire-shape refactor

Robot online at 192.168.1.173 (mDNS resolves now). Captured the live OpenAPI schema (79 endpoints, daemon v1.7.1, control loop 49.6 Hz / 20ms period). Created `sources/daemon-openapi-1.7.1.md` documenting deltas vs. our model. Major corrections:

- `/api/move/set_target` body uses `FullBodyTarget` with `target_` **prefixed** keys (`target_head_pose`, `target_antennas`, `target_body_yaw`). Head pose is XYZ+RPY by default, not a flat 16-element matrix. Matrix form is `{"m": [16 numbers]}` if used.
- `/api/move/goto` keys are **bare** (`head_pose`, `antennas`, `body_yaw`, `duration`, `interpolation`).
- `/api/state/full` returns `control_mode` (not `motor_mode`), `head_pose` (RPY object), `antennas_position` (not `antennas`), no `is_move_running` — derive from `/api/move/running` being non-empty.
- `WS /api/state/ws/full` exists and emits ~10 Hz; not advertised in OpenAPI.

Refactored to match the live wire:

- `RockyKit/RPYPose` added.
- `RockyKit/RobotState` switched to live shape (RPY pose, `control_mode`, `antennas_position`, optional `head_joints`/`passive_joints`/`doa`/`timestamp`).
- `RockyKit/MotionTarget` now serializes as `FullBodyTarget` with `target_*` keys.
- `RobotLink/RobotLinkClient.goto` rewritten with explicit `head_pose: RPYPose?`/`antennas`/`body_yaw`/`duration`/`interpolation`.
- `RobotLink/StateSubscriber` actor: WebSocket `/api/state/ws/full` with backoff reconnect; emits `RobotState` AsyncStream and publishes `motorState` telemetry events.
- `Vision/FaceTargetBridge` now produces `RPYPose` targets (was `HeadPose` matrix).
- `Rocky/MotionCard` added: live RPY bars (yaw/pitch/roll vs safety limits), antennas R/L, body yaw arc, motor-mode pill, frame-count pill.
- `AppServices` starts the StateSubscriber on launch and mirrors `lastRobotState` + `stateUpdateCount` on the main actor for SwiftUI consumption.

Live smoke test: posted `target_head_pose: {yaw: 0.0873}` (5°) → daemon returned `{"status":"ok"}` and the head moved (yaw climbed from baseline ~0.012 toward +0.041 in 700 ms before returning to 0). Wire format end-to-end confirmed.

Tests: 24/24 green (added `MotionTargetCodingTests` covering the `target_*` key encoding; rewrote `RobotState` decode test against a live capture).

## [2026-05-05] code | Rocky M4 — Voice pipeline base (no STT model yet)

Voice package landed with all the deterministic plumbing. STT is abstract; `EchoSTT` placeholder ships now, WhisperKit conformer follows.

- `Voice/AudioRingBuffer` — lock-protected SP/SC float32 ring; drops oldest under backpressure with a counter.
- `Voice/MicService` — AVAudioEngine input tap → 16 kHz mono float32 via `AVAudioConverter` → ring buffer. Tracks RMS for the VU meter.
- `Voice/EnergyVAD` — RMS-thresholded VAD with sliding minSpeechFrames / minSilenceFrames hysteresis. Trade-off documented vs. Silero.
- `Voice/STTEngine` protocol + `EchoSTT` test conformer.
- `Voice/WakeFilter` actor — **address-pattern** wake match (transcript must START with "rocky" after stripping leading "hey"/"ok"/punctuation/whitespace; "the rocky road" no longer matches). 60s rolling conversation window with auto-extend on each turn; stop phrases close it; `openWindow`/`closeWindow` for manual control.
- `Voice/VoiceCoordinator` actor — orchestrates frame source → VAD → STT → WakeFilter; emits `Output` events (partial, finalText with dispatched flag, windowOpened/Closed).
- `Rocky/VoiceCard` — VU meter, conversation pill (countdown when open, "waiting for wake word" when closed), last transcript, dispatched indicator, mic toggle button.
- `AppServices.toggleMic()` starts mic + voice coordinator and pumps outputs into Observable mirrors.

Tests (13 new, 37/37 total):
- `AudioRingBufferTests` (3): round-trip, overflow drops oldest, partial reads advance tail.
- `EnergyVADTests` (3): speechStart latches after enough loud frames; speechEnd after enough silent; intermittent loud frames don't latch.
- `WakeFilterTests` (6): "the rocky road" ignored; "Rocky, ..." routed; follow-up within window without wake; window expires; stop phrase closes; manual openWindow/closeWindow.
- `VoiceCoordinatorTests` (1): scripted-frame end-to-end — VAD start, segment, end → STT fires → wake match dispatches.

WhisperKit (real STT) lands next as a follow-up commit.

## [2026-05-05] code | Rocky M6 base — Cognition (LM Studio + tools)

Cognition package + dashboard wiring. Pure URLSession SSE; no SDK lock-in.

- `Cognition/JSONValue` — round-trippable JSON value type for tool args/schemas without modeling JSON-Schema in Swift.
- `Cognition/SSEParser` — minimal `data: ...\n\n` parser; tested.
- `Cognition/LMStudioClient` actor — `listModels()` + `chatStream(messages:tools:)`. OpenAI-compatible. Default `http://localhost:1234/v1`. No auth (overridable). Streams `ChatChunk(contentDelta, toolCallDeltas, finishReason)` from SSE; correlates `tool_call_deltas[i].function.arguments` across deltas.
- `Cognition/ToolRegistry` actor — schema + handler pairs; `invoke(name:argumentsJSON:llmMessageId:)` returns a `ToolResult` with full args/result/latency/ok and emits `toolInvocation` telemetry.
- `Cognition/CognitionEngine` actor — runs a turn against the LLM, dispatches tool calls (capped at `maxToolRounds = 4`), feeds results back as `tool` messages, surfaces a typed `Output` stream (`assistantDelta`, `assistantFinal`, `toolCallDispatched`, `toolCallResult`).

Initial tools wired into `AppServices.registerInitialTools()`:
- `look_at(yaw_deg, pitch_deg, duration_s?)` → `RobotLink.goto(headPose:duration:)` with RPY pose
- `set_motor_mode(mode)`
- `wake_up`, `go_to_sleep`, `stop_motion`
- `say(text)` — stub that emits `tts_request` telemetry (real TTS lands in M5)
- `get_state` — fetches `/api/state/full` and returns degree-friendly snapshot

Dashboard `BrainCard`:
- Status pill: green = model name, red = "brain offline", gray = checking
- Scrolling chat-style transcript with `you` / `rocky` / `tool` badges
- Tool calls render as expandable disclosure rows showing args/result JSON
- Latency pills on assistant messages: TTFT (first chunk) and total
- Inline text input + Send button (Return submits)
- Reset button to clear conversation

`AppServices`:
- Probes `/v1/models` on launch; flips `llmStatus` to `online(model)` or `offline(reason)` honestly.
- `sendUserText(_)` runs a turn, mirrors deltas live into `brainTurns` so SwiftUI redraws as the assistant streams.
- Voice→Brain wired: dispatched final transcripts auto-route into `sendUserText`.

10 new tests (47/47 total): SSE record boundaries + partial buffering; `JSONValue` round-trip + parsing; `ToolRegistry` happy path, unknown tool, malformed args, schemas surface.

LM Studio not running locally — confirmed graceful degradation: `BrainCard` shows "brain offline", manual sends echo a polite "(brain offline · …)" reply.

## [2026-05-05] code | Rocky M5 base — TTS via robot speaker

Voice out shipped end-to-end with a `say` placeholder backend so the wire path is provable today; F5-TTS-MLX swap is a one-file change inside the sidecar.

Sidecar `Sidecars/mlx-tts/`:

- Two pluggable backends share one `Backend` interface:
  - **`say`** (default) — macOS bundled TTS via `say -o file.aiff` + `afconvert -f WAVE -d LEI16@16000`. Always available, no Python deps.
  - **`f5-tts-mlx`** (gated behind `[mlx]` extras) — F5-TTS-MLX engine for cloned voice. Activated by `ROCKY_TTS_BACKEND=f5-tts-mlx` once the user provides a 5–10 s reference WAV.
- Methods: `synthesize(text, voice_ref_id?)` returns base64 WAV + sample rate + duration + synth_ms; `set_voice_ref(name, wav_b64)`; `health()`; `warm_up()`.
- Smoke test: `say` backend produces 1.15 s of "hi from rocky" in ~836 ms.

`RobotLink/MediaClient` actor:

- `uploadSound(filename, data)` — multipart/form-data POST to `/api/media/sounds/upload`. Returns the daemon's stored path.
- `playSound(file)` — JSON POST to `/api/media/play_sound`.
- `stopSound()` — POST `/api/media/stop_sound`.

Live wire confirmed: posted `say` output → upload (200 OK, path `/tmp/reachy_mini_sounds/rocky_test.wav`) → play_sound (200 OK) → robot's onboard speaker said "hello, I am Rocky" out loud.

`Voice/RobotTTS` actor:

- `speak(text)` — synthesize → upload → play; returns `SpeakStats(synthMs, uploadMs, totalMs, durationS)`.
- `setVoiceRef(name, wavData)` — forwards to the sidecar.
- `cancel()` — calls `stopSound`.
- `start()` / `stop()` — sidecar lifecycle.

`AppServices`:

- `mlx-tts` sidecar registered with the supervisor via a dev manifest (`/usr/bin/python3` + `say` backend). Spawned in the background on launch.
- `say` tool handler now calls `robotTTS.speak(text)` and returns real `synth_ms` / `upload_ms` / `duration_s` to the LLM.
- `stop_speaking` tool registered.

The vertical slice "voice → brain → robot" is now real end-to-end (modulo STT — WhisperKit lands as a follow-up). Once LM Studio and the user's voice reference are in place, Rocky can hear, think, and talk.

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
