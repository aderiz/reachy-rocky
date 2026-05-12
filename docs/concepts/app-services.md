---
title: AppServices — the orchestration core
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Rocky/AppServices.swift
  - Sources/Rocky/RockyApp.swift
tags: [appservices, lifecycle, orchestration, observable]
---

# AppServices

`AppServices` is the single `@Observable @MainActor` class that owns
every long-lived component in Rocky and exposes the observable state
SwiftUI binds to. If you can't find where two subsystems talk to
each other, the answer is almost always "via `AppServices`."

Defined at `Sources/Rocky/AppServices.swift:18` —
`final class AppServices` — and instantiated once at app launch from
`RockyApp.swift`. It's `@MainActor` so it can carry SwiftUI-readable
observable state, and `@Observable` so each property mutation
re-renders any views that read it.

## What it owns

The `let` properties at the top of the file are the service
inventory. They're grouped by concern and constructed in order in
`init(settings:)` so dependencies flow top-down. Material entries:

| Property | Type | Created at | Role |
|---|---|---|---|
| `settings` | `SettingsStore` | `:19` | UserDefaults wrapper. Read once at init, hot-applied via `applySettings`. |
| `logBus` | `LogBus` | `:20` | Pub/sub event sink. Every subsystem publishes; LogsView + MomentFeed subscribe. |
| `robotEndpoint` | `RobotEndpoint` | `:21` | Captured at init — endpoint changes are relaunch-required. |
| `robotLink` | `RobotLinkClient` | `:22` | REST + WebSocket client to the daemon. |
| `supervisor` | `SidecarSupervisor` | `:23` | Runs all sidecar processes with restart + circuit-breaker policy. |
| `targetStreamer` | `TargetStreamer` | `:24` | 50 Hz set_target stream to the daemon. |
| `robotCamera` | `RobotCameraService` | `:25` | Consumes the on-bot relay's `/ws/video`. |
| `macFaceTracker` | `MacFaceTracker` | `:26` | Apple Vision face detection on camera frames. |
| `faceLibrary` | `FaceLibrary` | `:27` | Enrolled face feature-prints + identity matching. |
| `stateSubscriber` | `StateSubscriber` | `:28` | WS subscriber on `/api/state/ws/full`. |
| `wakeEngine` | `any WakeWordEngine` | `:29` | STT-derived by default; Porcupine slot. |
| `battery` | `BatteryService` | `:33` | Polls `/battery` on the on-bot relay. |
| `brainSidecar` | `SidecarRuntime?` | `:37` | MLX-VLM brain. Nil if venv missing. |
| `mlxSTTSidecar` | `SidecarRuntime?` | `:41` | MLX-Whisper STT. Nil if venv missing. |
| `streamingTTS` | `StreamingTTS` | `:44` | PCM chunk player + echo-gate driver. |
| `audioBuffer` | `AudioRingBuffer` | `:47` | Shared by mic + robotMic. |
| `mic` / `robotMic` | `MicService` / `RobotMicService` | `:48`–`:49` | Two mic sources writing into the shared buffer. |
| `wakeFilter` | `WakeFilter` | `:50` | Conversation-window state machine. |
| `voice` | `VoiceCoordinator` | `:51` | Wires mic → VAD → STT → wake → dispatch. |
| `addressFilter` | `AddressFilter` | `:57` | Strict post-STT pre-brain gate (see [address-filter](address-filter.md)). |
| `appleSTT` | `AppleSpeechSTT` | `:58` | Fallback STT. |
| `mediaClient` | `MediaClient` | `:59` | HTTP client to the daemon's `play_sound` endpoint. |
| `robotTTS` | `RobotTTS` | `:60` | Legacy non-streaming TTS path. |
| `permissions` | `PermissionsAuthority` | `:66` | TCC state machine. |
| `llm` | `LMStudioClient` | `:69` | HTTP client for the LM Studio fallback brain. |
| `toolRegistry` | `ToolRegistry` | `:70` | Tool schema + handler dispatch. |
| `cognition` | `CognitionEngine` | `:71` | Brain orchestration — manages turn loops, tool calls, memory. |
| `memory` | `MemoryService` | `:72` | mempalace sidecar wrapper. |
| `momentFeed` | `MomentFeed` | `:76` | Coalesces `LogBus` events into UI-facing "moments." |

The optional sidecars (`brainSidecar`, `mlxSTTSidecar`) are nil when
their venv isn't installed at
`~/Library/Application Support/Rocky/sidecars/<name>/.venv/`. In
that case the corresponding feature falls back: brain → LM Studio,
STT → WhisperKit → Apple Speech.

## Observable state surface

All `var` properties at `AppServices.swift:79+` are `@Observable`
slots SwiftUI reads. Most-touched:

- **Robot status**: `daemonReachability`, `lastDaemonStatus`,
  `lastRobotState`, `stateUpdateCount`, `transitioningUntil`,
  `isAsleep`, `rockyState`.
- **Face tracking**: `lastFaceDetection`, `lastFaceTarget`,
  `faceTrackingEnabled`, `enrolledPeople`.
- **Camera**: `lastCameraFrame`, `lastCameraFrameAt`,
  `cameraFrameCount`, `visionEnabled`.
- **Voice**: `micEnabled`, `lastMicRMS`, `lastTranscript`,
  `lastDispatched`, `conversationOpenUntil`, `ttsBusyUntil`,
  `ttsMuted`.
- **Brain**: `llmStatus`, `brainTurns`, `brainBusy`,
  `brainErrorMessage`, `availableLLMModels`.
- **Battery**: `latestBattery`.
- **Sidecar lifecycle**: `ttsSidecarState`, `memorySidecarState`,
  `brainSidecarState`.
- **Memory**: `memoryDrawerCount`.
- **Telemetry**: `recentMoments`.
- **Commands**: `commandPaletteOpen`, `dndUntil`, `isDoNotDisturb`.
- **Computed**: `healthGlance`, `botMode`, `effectiveTTSMuted`.

Mutations happen on `MainActor.run { ... }` blocks because all the
back-end work (sidecars, networking, file IO) runs off the main
actor.

## Lifecycle — `start()`

`AppServices.swift:start()` (~line 727) is the entry point called
once from `RockyApp` after instantiation. Idempotent enough to be
safe to call once. Phases:

1. **Memory bring-up**. `await memory.start()` — best-effort; if
   the mempalace venv isn't built, this fails cleanly and memory
   recall is skipped on subsequent turns.
2. **Brain backend selection**. `applyBrainBackend()` swaps between
   MLX-VLM and LM Studio per `settings.brainBackend`.
3. **LogBus → MomentFeed pump.** Detached `Task`s convert raw events
   into narrative moments mirrored onto `recentMoments`.
4. **Sidecar starts.** `streamingTTS`, `mlxSTTSidecar`,
   `brainSidecar` (when present), `memory` (mempalace), the
   `robot-mic` and `robot-camera` subscribers. Each respects the
   sidecar supervisor's restart policy + circuit breaker.
5. **`ensureRelayAppRunning`** — fire-and-forget probe of the
   daemon's `/api/apps/current-app-status`; auto-starts
   `rocky_media_relay` if nothing else is running. See
   [on-bot-media-relay](on-bot-media-relay.md).
6. **Battery poller.** `battery.start()` + an `AsyncStream` pump
   that mirrors snapshots into `latestBattery`.
7. **Initial tool registration.** `registerInitialTools()` wires
   every shipped tool into the registry.
8. **FastPath wiring.** Builds the intent matcher (sub-second
   answers for time / weather / search / greeting / remember) and
   hands it to `cognition.setFastPath`.
9. **LM Studio probe** + 8 s retry loop (only when LM Studio is the
   active brain backend — avoids hammering a closed port when
   MLX-VLM is in charge).
10. **Voice pump.** Subscribes to `voice.outputs` and drives
    `handleVoice(_:)` for every transcript event.
11. **State subscriber** + face-target / camera-frame pumps.
12. **First-run permission probe** if `settings.firstRunCompleted == false`.

After `start()` returns, the app is fully alive. Each subsystem
operates independently; the three big loops described in CLAUDE.md
(robot state at 10 Hz, face tracker at 50 Hz, voice event-driven)
run concurrently.

## State-mutation discipline

Two non-obvious rules:

**Always mutate on `MainActor.run { self.foo = ... }`.** Even if the
calling actor is `AppServices`, async hops can land off-main; SwiftUI
crashes if `@Observable` properties mutate off main. Look for
`await MainActor.run { ... }` throughout — that's the convention.

**Read services from inside view bodies, never write.** `EnrollFaceForm`
(`SettingsView.swift:768`) explicitly comments on this: writing
`services.something` from a view body re-invalidates the view at
every external mutation (camera frames, robot state) and steals
TextField focus. Reads inside Task closures / button actions are
fine.

## How to add a new long-lived service

1. Declare the property near the related cluster (e.g. add a new
   sidecar service near the existing `streamingTTS` /
   `mlxSTTSidecar`).
2. Build it in `init(settings:)` with the same fall-back-on-missing-
   venv pattern if it's optional.
3. Start it in `start()` after its dependencies are alive.
4. If it produces a stream, spawn a detached `Task` that mirrors
   events onto the observable surface via `MainActor.run`.

## See also

- [Rocky — architecture](rocky-architecture.md) — three-loop
  diagram, threads of control.
- [Voice / listen pipeline](voice-pipeline.md) — what
  `voice` + `handleVoice` actually do.
- [Sidecar convention](sidecar-convention.md) — the contract
  every entry under `Sidecars/` follows.
- [Settings store](../reference/settings-store.md) — every
  UserDefaults key + migration notes.
- [Application Support layout](../reference/application-support-layout.md)
  — where on-disk state lives.
