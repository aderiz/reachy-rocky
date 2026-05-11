---
title: Rocky — architecture
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/agents-md.md
  - sources/daemon-openapi-1.7.1.md
tags: [rocky, architecture]
---

# Rocky — architecture

Rocky is a native macOS app that acts as the *nervous system* for a Reachy Mini Wireless robot. Cognition (LLM brain), perception (face tracking), audition (mic + STT), voice (cloned-voice TTS), and observability all run on the Mac; the robot is reduced to a clean network endpoint.

## One picture

```
+--------------------------- Rocky.app (macOS) ---------------------------+
|                                                                         |
|  WindowGroup                                  MenuBarExtra              |
|     RootView (sidebar + detail)                  state-driven SF symbol |
|       Dashboard / Status / Logs / Settings       quick actions          |
|                                                                         |
|  AppServices (@Observable, @MainActor)                                  |
|     |--- LogBus  (broadcasts every TelemetryEvent)                      |
|     |--- SettingsStore (UserDefaults: endpoint, model, persona)         |
|     |                                                                   |
|     |--- RobotLink                                                      |
|     |     |- RobotLinkClient (REST, motion, motors, daemon, state)     |
|     |     |- StateSubscriber (WebSocket, backoff)                       |
|     |     |- TargetStreamer  (50 Hz set_target tick)                    |
|     |     \- MediaClient     (sound upload + play)                      |
|     |                                                                   |
|     |--- Vision                                                         |
|     |     |- FaceTrackerService  (sidecar adapter)                      |
|     |     \- FaceTargetBridge    (target -> TargetStreamer)             |
|     |                                                                   |
|     |--- Voice                                                          |
|     |     |- MicService     (AVAudioEngine, 16 kHz mono)                |
|     |     |- EnergyVAD                                                  |
|     |     |- AppleSpeechSTT (default; STTEngine protocol = pluggable)  |
|     |     |- WakeFilter     (address-pattern + 60s window)              |
|     |     |- VoiceCoordinator                                           |
|     |     |- StreamingTTS    (PCM chunks -> WAV -> robot speaker)       |
|     |     \- RobotTTS        (sidecar -> StreamingTTS.playToRobot)      |
|     |                                                                   |
|     |--- Cognition                                                      |
|     |     |- BrainBackend protocol                                      |
|     |     |   |- MLXVLMBrain    (default; brain sidecar, vision-aware)  |
|     |     |   \- LMStudioBrain  (fallback; URLSession SSE, text-only)   |
|     |     |- ToolRegistry   (handlers wired into RobotLink/Voice)       |
|     |     \- CognitionEngine (turn loop, tool dispatch, transcript;     |
|     |                         imageProvider feeds latest camera frame)  |
|     |                                                                   |
|     |--- Perception                                                     |
|     |     \- MacFaceTracker  (Apple Vision; consumes robot-camera frames|
|     |                         and pushes targets into TargetStreamer)   |
|     |                                                                   |
|     \--- SidecarSupervisor                                              |
|           |- brain         (Python + mlx-vlm + Qwen3-VL 4B Instruct 4b) |
|           |- face-tracker  (Python; synthetic-target test scaffold)     |
|           |- robot-camera  (Python; WebRTC RGB stream)                  |
|           |- robot-mic     (Python; WebRTC 4-mic ReSpeaker)             |
|           |- mempalace     (Python; local memory store)                 |
|           \- mlx-tts       (Python + Qwen3-TTS-12Hz-1.7B-Base-bf16)     |
|                                                                         |
+-------------------------------------------------------------------------+
        |                                |                       |
        v                                v                       v
   reachy-mini.local:8000          localhost:1234/v1        local stdio
   (REST + WS + WebRTC)            (LM Studio fallback)     (sidecars)
```

## Threads of control

Live data flows in **three independent loops**, each with its own cadence and ownership:

1. **Robot state loop** (~10 Hz). `StateSubscriber` reads the daemon's `WS /api/state/ws/full` stream → `LogBus.motorState` → `AppServices.lastRobotState` → `MotionCard` redraws.
2. **Face-tracker target loop** (50 Hz). Active path: `robot-camera` JPEG stream → `MacFaceTracker` (Apple Vision `VNDetectFaceRectanglesRequest`) → EMA + critically-damped controller → `TargetStreamer` → `POST /api/move/set_target`. The Python `face-tracker` sidecar is a synthetic-target test scaffold (Lissajous), wired in via `FaceTrackerService` → `FaceTargetBridge` for development without a robot or camera.
3. **Voice / brain / TTS loop** (event-driven). Mic → VAD → STT → WakeFilter → `CognitionEngine` → at turn start `imageProvider()` captures `lastCameraFrame` (gated by `visionEnabled`) → `BrainBackend.chatStream(messages, tools, image)` → tool dispatch (which may invoke `say` → `RobotTTS.speakStreaming` → mlx-tts → PCM chunks → `StreamingTTS.playToRobot` → daemon `play_sound` on the robot speaker). The turn ends when `say` returns OK; the engine does not loop back to the brain after speaking. The chat bubble is the `say` tool's `text` argument, so chat and audio agree.

These loops never call into each other directly. Cross-loop signaling happens through `LogBus`, Observable mirrors on the main actor, or actor-message methods (e.g. `setSuppressed`).

## State machine: `RockyState`

Computed from sub-states; one source of truth for the Hero card label, MenuBar symbol, animations:

| State | Trigger |
|---|---|
| `.error(reason)` | Daemon offline, voice error, etc. |
| `.speaking` | `ttsBusyUntil` is in the future |
| `.thinking` | `brainBusy` is true |
| `.listening` | mic on or conversation window active |
| `.idle` | none of the above |

## Module dependency layers

```
RockyKit ─┐
          ├── Telemetry ─┐
          │              ├── SidecarHost ──┐
          │              │                 ├── Vision ─┐
          │              │                 │           │
          │              ├── RobotLink ────┼── Voice ──┼── Rocky (app)
          │              │                 │           │
          │              ├── Cognition ────┴───────────┘
          │              │
          │              └─ (LogBus, TelemetryEvent — depends on RockyKit)
          │
          └─ (HeadPose, RPYPose, Antennas, MotorMode, RobotState, MotionTarget)
```

`Voice` depends on `RobotLink` because `RobotTTS` needs `MediaClient` for the upload+play path. `Vision` depends on `RobotLink` for the type used by `FaceTargetBridge`.

## Persistence

| Layer | What | Where |
|---|---|---|
| `SettingsStore` | endpoint, model, API key, persona | UserDefaults |
| Telemetry archive | every event, indexed by timestamp | SQLite WAL (planned, M8) |
| Conversation history | per-turn messages + tool traces | SwiftData (planned, M6 follow-up) |
| Sidecar venvs | per-sidecar `.venv/` and model cache | `~/Library/Application Support/Rocky/` |

## Robot-side wire shapes (live-validated, 2026-05-05)

Source of truth: the live OpenAPI snapshot at [`sources/daemon-openapi-1.7.1.md`](../sources/daemon-openapi-1.7.1.md). Notable differences from intuition:

- `set_target` body uses `target_*` prefixed keys; `goto` uses bare keys.
- `state/full` returns `head_pose` as RPY (object), not a flat 16-element matrix.
- `is_move_running` is **not** in `state/full` — derive from `/api/move/running`.
- WebSocket lives at `ws://reachy-mini.local:8000/api/state/ws/full` despite not being advertised in OpenAPI.

## See also

- [Sidecar convention](sidecar-convention.md)
- [Motion philosophy](motion-philosophy.md)
- [Daemon OpenAPI snapshot](../sources/daemon-openapi-1.7.1.md)
- [App lifecycle](app-lifecycle.md)
