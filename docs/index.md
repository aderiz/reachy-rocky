---
title: Wiki Index
type: index
last_updated: 2026-05-12
---

# Index

The catalog of every page in the wiki.

## Concepts

- [Rocky — architecture](concepts/rocky-architecture.md) — block diagram, threads of control, layer dependencies.
- [Sidecar convention](concepts/sidecar-convention.md) — wire protocol, manifest, lifecycle.
- [Architecture](concepts/architecture.md) — daemon/SDK split, where code runs, REST + WebRTC transports.
- [Motion philosophy](concepts/motion-philosophy.md) — `goto_target` for gestures, `set_target` in a control loop.
- [Coordinate frames](concepts/coordinate-frames.md) — head frame, world frame, units (mm, deg, rad).
- [Safety limits](concepts/safety-limits.md) — joint ranges, head/body yaw delta, auto-clamping.
- [Media architecture](concepts/media-architecture.md) — `local`/`webrtc`/`no_media` backends, GStreamer/IPC.
- [App lifecycle](concepts/app-lifecycle.md) — entry points, single-app constraint, SIGINT shutdown.
- [Cockpit design](concepts/cockpit-design.md) — UI design contract: stage + margin + drawer + toolbar window, menu bar as persistent surface, six-wave roadmap.
- [Voice / listen pipeline](concepts/voice-pipeline.md) — mic → ring buffer → VAD → STT → wake filter → **AddressFilter** → cognition; four-phase calibration with motors-under-load + DoA, Whisper hallucination mitigation, echo gate.
- [AddressFilter](concepts/address-filter.md) — strict post-STT pre-brain dispatch gate fusing loudness, DoA, face, confidence; wake-name now requires real audio energy so Whisper hallucinations can't wake the bot.
- [Portrait composition](concepts/portrait.md) — avatar + senses chip + power chip + name plate + wake toggle; light/dark backdrop, iOS-style switch + battery chip, single-source-of-truth bindings.
- [Tools registry](concepts/tools-registry.md) — schema/handler shape, dispatch path, fenced-JSON fallback for Gemma, inventory of the shipped tools.
- [Permissions authority](concepts/permissions-authority.md) — single source of truth, 5-state enum, TCC + signing pitfalls, debug-binary trap.
- [On-bot media relay](concepts/on-bot-media-relay.md) — `rocky_media_relay` Reachy Mini App + Mac-side WS subscribers; replaces WebRTC.

## Reference

- [Hardware](reference/hardware.md) — physical specs of the Wireless variant.
- [Python SDK](reference/sdk-python.md) — `ReachyMini` class API surface.
- [Motors](reference/motors.md) — IDs, names, ranges, common faults; antenna anti-vibration constraint; supply-voltage register pointer.
- [Power monitoring](reference/power-monitoring.md) — the bot has no fuel gauge; supply voltage is read via Dynamixel reg 144 through the daemon's raw-packet WS and surfaced via the on-bot relay's `/battery` endpoint. LiFePO4 SOC mapping.
- [Glossary](reference/glossary.md) — terms.

## Workflows

- [Dev loop on Wireless](workflows/dev-loop-wireless.md) — sshfs Approach A (recommended).
- [Create an app](workflows/create-app.md) — `reachy-mini-app-assistant` CLI.
- [Run and debug](workflows/run-and-debug.md) — daemon logs, `journalctl`, common pitfalls.
- [Deploy the on-bot media relay](workflows/deploy-media-relay.md) — `reachy-mini-app-assistant check/publish`, dev-iteration loop on the bot, start/stop via daemon REST.

## Patterns

- [Control loop](patterns/control-loop.md) — single 100 Hz loop, pose computation per tick.
- [Recorded moves](patterns/recorded-moves.md) — record/replay + Pollen emotions library.
- [Direct hardware access](patterns/direct-hardware.md) — `media_backend="no_media"` + OpenCV/sounddevice.

## Sources

- [AGENTS.md](sources/agents-md.md) — canonical AI-agent guide for the Reachy Mini repo.
- [HF Docs map](sources/hf-docs.md) — pages we've ingested from huggingface.co/docs/reachy_mini.
- [Daemon OpenAPI v1.7.1](sources/daemon-openapi-1.7.1.md) — live wire shapes captured from the running daemon, including `set_target` / `goto` / `state/full` corrections and newly discovered media endpoints.

## Decisions

- [0001 — Target platform](decisions/0001-target-platform.md) — Wireless on-robot Python is the default for upstream Pollen apps.
- [0002 — Rocky as a macOS-native nervous system](decisions/0002-rocky-app.md) — explains why Rocky is a Swift app, not a Python app on the CM4.
- [0003 — Sidecar convention for external processes](decisions/0003-sidecar-convention.md) — JSON manifests, line-delimited JSON wire format, supervisor with restart policy + circuit breaker.
- [0005 — Brain backend as a protocol, MLX-VLM as the default](decisions/0005-brain-backend-protocol.md) — `BrainBackend` seam, vision-aware default, Status panel resolves rows by active backend.

## Rocky implementation

The Rocky macOS app lives in `Sources/`, `Tests/`, `Sidecars/`. Top-level
README: `README.md` (install + day-to-day commands). Plan:
`~/.claude/plans/i-d-like-this-to-swirling-octopus.md` (historical).

Swift packages (see `Package.swift`):

- `RockyKit` — value types: `HeadPose`, `Antennas`, `MotorMode`, `SafetyLimits`, `RobotState`, `MotionTarget`, units.
- `Telemetry` — `LogBus`, `TelemetryEvent` taxonomy.
- `SidecarHost` — `Sidecar` protocol, `SidecarManifest`, `JSONLineCodec`, `SidecarRuntime`, `SidecarSupervisor`.
- `RobotLink` — `RobotLinkClient`, `TargetStreamer`, `StateSubscriber`, `MediaClient`.
- `RockyVision` — `FaceTrackerService`, `RobotCameraService`, `FaceTargetBridge`.
- `Voice` — `MicService` / `RobotMicService`, `AudioRingBuffer`, `EnergyVAD`, `AppleSpeechSTT`, `WakeFilter`, `VoiceCoordinator`, `RobotTTS`.
- `Cognition` — `LMStudioClient`, `SSEParser`, `ToolRegistry`, `CognitionEngine`, `JSONValue`.
- `Memory` — `MemoryService` (mempalace sidecar wrapper).
- `Perception` — `MacFaceTracker`, `FaceLibrary` (Apple Vision feature-print enrolment).

Sidecars (`Sidecars/`):

- `face-tracker` — synthetic-target test scaffold (Lissajous pattern, stdlib only). Real face tracking is Swift-side in `Sources/Perception/MacFaceTracker.swift` (Apple Vision on `robot-camera` frames); the sidecar's `[sam]` mode was never implemented.
- `robot-mic` — 4-mic ReSpeaker array; v0.2 subscribes to the on-bot `rocky_media_relay` over WebSocket (was WebRTC).
- `robot-camera` — RGB stream; v0.2 subscribes to the on-bot `rocky_media_relay` over WebSocket (was WebRTC). Frames still feed `MacFaceTracker`.
- (on bot) `rocky_media_relay` — Reachy Mini App that captures the camera + mic locally and exposes them at `ws://reachy-mini.local:8042/ws/{audio,video}`. Source: `OnBot/rocky_media_relay/`.
- `mlx-tts` — Chatterbox FP16 voice cloning (default `say` backend without ML extras).
- `mempalace` — local memory store (recall + record).
- `echo` — reference / contract test.

Rocky app (`Sources/Rocky/`): cockpit window with portrait + conversation +
moment strip, inspector drawer, menu-bar extra, Settings tabs (Brain,
Voice, Memory, Faces, Permissions). First-run overlay walks new owners
through prerequisites.

## Open gaps

Items we know about but haven't ingested yet. See `log.md` for the latest status.

### `skills/` files (referenced by AGENTS.md)

- `skills/symbolic-motion.md` — mathematical motion definitions (dances, rhythms).
- `skills/interaction-patterns.md` — antennas-as-buttons, head-as-joystick.
- `skills/ai-integration.md` — LLM-powered apps.
- `skills/safe-torque.md` — enable/disable motors smoothly.
- `skills/create-app.md` — full app creation workflow.
- `skills/rest-api.md` — full daemon REST API.
- `skills/testing-apps.md` — sim vs physical pre-delivery testing.
- `skills/setup-environment.md` — first-session bootstrap.
- `skills/debugging.md` — crash / connectivity diagnosis.
- `skills/deep-dive-docs.md` — when to read SDK docs in full.

### Examples (only `look_at_image.py` ingested in full)

- `minimal_demo.py`, `imu_example.py`, `joy_controller.py`, `recorded_moves.py`, `sequence.py`, `sound_doa.py`, `sound_play.py`, `sound_record.py`, `take_picture.py`, `mini_head_position_gui.py`, `reachy_compliant_demo.py`, `rerun_viewer.py`, `goto_interpolation_playground.py`, `custom_media_manager.py`.

### Reference apps

- `reachy_mini_conversation_app/src/reachy_mini_conversation_app/moves.py` — canonical primary/secondary fusion impl.

### Other

- JS SDK page (`SDK/javascript-sdk`).
- Tutorials notebook 0 + 1 contents.
- Live daemon OpenAPI schema (`http://reachy-mini.local:8000/openapi.json`).
- `platforms/reachy_mini/media_advanced_controls` — camera/mic param tuning.
- `troubleshooting/motors_diagnosis` — deep motor fault tree.
