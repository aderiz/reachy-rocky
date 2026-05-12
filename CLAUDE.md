# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**Rocky** — a native macOS app that acts as the *nervous system* for a **Reachy Mini Wireless** robot. Cognition (MLX-VLM brain with vision; LM Studio is the text-only fallback), perception (face tracking), audition (mic + STT), voice (cloned-voice TTS via Qwen3-TTS-12Hz-1.7B-Base-bf16 ICL), and observability all run on the Mac; the robot is reduced to a clean network endpoint over REST + WebSocket. Audio plays only through the robot speaker — the Mac stays silent.

- **OS target**: macOS 15+, Apple Silicon. Swift 6, SwiftUI.
- **Bundle ID**: `ai.amplified.Rocky` (drives TCC, `defaults read/write`, Console.app filtering).
- **Robot variant**: Wireless (CM4 onboard, WiFi). Daemon at `http://reachy-mini.local:8000` — live OpenAPI snapshot in `docs/sources/daemon-openapi-1.7.1.md`.
- **Brain**: MLX-VLM sidecar (`Sidecars/brain/`) loading `mlx-community/Qwen3-VL-4B-Instruct-4bit` by default. Gemma 4 26B-A4B (also vision-capable) works via the same sidecar. LM Studio fallback at `localhost:1234/v1` when explicitly selected or auto + sidecar absent.

The implementation plan lives at `~/.claude/plans/i-d-like-this-to-swirling-octopus.md`. Always read it for the rationale behind a structural choice before changing one.

## Big-picture architecture

Three independent loops, each with its own cadence and ownership. They never call each other directly — cross-loop signalling happens via the `LogBus` actor or `@Observable` state on `AppServices` (the main-actor singleton). See `docs/concepts/rocky-architecture.md` for the diagram.

1. **Robot state loop** (~10 Hz). `StateSubscriber` reads the daemon's `WS /api/state/ws/full` → mirrors into `AppServices.lastRobotState` → `MotionCard` redraws.
2. **Face-tracker target loop** (50 Hz). Active path: `robot-camera` JPEG stream → `MacFaceTracker` (`Sources/Perception/`) running Apple Vision's `VNDetectFaceRectanglesRequest` on every frame → EMA + critically-damped controller → `TargetStreamer` → `POST /api/move/set_target`. The Python `face-tracker` sidecar is a **synthetic-target test scaffold** (Lissajous pattern) used for development without a robot or camera; its targets enter Rocky via `FaceTrackerService` → `FaceTargetBridge` but are normally dormant in shipped use. SAM 3.1 was the original M3b plan but never implemented — the sidecar's runner falls through to the synthetic detector if you set `ROCKY_FT_MODE=sam`.
3. **Voice / brain / TTS loop** (event-driven). Mic → VAD → STT → `WakeFilter` (admit) → `AddressFilter` (strict multi-signal dispatch gate) → `CognitionEngine` → `ToolRegistry` (which may invoke `RobotTTS.speak` → `mlx-tts` sidecar → `MediaClient` upload + `play_sound`). The `AddressFilter` fuses segment loudness, DoA (robot mic), face engagement, STT confidence, and a junk-phrase deny-list — wake-name still wins but only if the segment has real audio energy. See `docs/concepts/voice-pipeline.md` + `docs/concepts/address-filter.md`.

### The Sidecar contract — *the* invariant

External processes (Python ML, robot-mic, TTS engine) ALL run under one convention: `SidecarHost`. Swift never `Process.run`s ad hoc. Read `docs/concepts/sidecar-convention.md` and ADR `docs/decisions/0003-sidecar-convention.md` before changing anything in `Sources/SidecarHost/` or adding a new sidecar.

The wire is line-delimited JSON over stdin/stdout. Adding a new sidecar = drop a directory in `Sidecars/<name>/` (`manifest.json` + `pyproject.toml` + `setup.sh` + `runner.py`) and a thin Swift adapter. Use `Sidecars/echo/` as the canonical reference; the integration test in `Tests/SidecarHostTests/EchoSidecarIntegrationTests.swift` proves the contract end-to-end including `kill -9` recovery.

### Robot wire-shape gotchas

These are easy to get wrong. Source of truth: `docs/sources/daemon-openapi-1.7.1.md` (live capture).

- `POST /api/move/set_target` body uses **`target_*`** prefixed keys (`target_head_pose`, `target_antennas`, `target_body_yaw`).
- `POST /api/move/goto` uses **bare** keys (`head_pose`, `antennas`, `body_yaw`, `duration`, `interpolation`).
- `GET /api/state/full` returns `control_mode` (NOT `motor_mode`), `head_pose` as **RPY object** (NOT a 16-element matrix), `antennas_position` (NOT `antennas`).
- `is_move_running` is NOT in `state/full`; derive from `/api/move/running` being non-empty.
- The state WebSocket lives at `ws://reachy-mini.local:8000/api/state/ws/full` despite not being advertised in OpenAPI.

### LLM tool-call format (Gemma fallback)

Some models — Gemma 4 in particular — don't reliably emit OpenAI `tool_calls`. They wrap invocations in markdown ` ```json ` fences instead. `CognitionEngine.extractFencedToolCalls` recovers these as real tool calls and `stripFencedJSONBlocks` keeps the displayed transcript clean. The persona prompt (`SettingsStore.defaultPersona`) documents both formats. **Don't remove either path** without verifying the active model emits native `tool_calls`.

For models with strong native tool calling (e.g., `qwen3.6-27b@4bit`), the fenced path is a no-op fallback.

## Build, run, test

```bash
# Headless build (libraries + executable)
swift build

# Full test suite (76 tests across 18 suites; integration tests spawn echo + face-tracker sidecars)
swift test

# Filter to one suite
swift test --filter "Sidecar host"
swift test --filter "WakeFilter"
swift test --filter "AddressFilter"

# Build a proper macOS .app bundle (with Info.plist + ad-hoc codesign).
# Use this — NOT `swift run` — because TCC permission prompts (mic,
# speech recognition) only fire reliably for a real bundled app.
./scripts/build-app.sh
open build/Rocky.app

# One-shot equivalent
./scripts/run.sh
```

Open `Package.swift` directly in Xcode for IDE indexing. Note: `⌘R` in Xcode runs the raw SwiftPM executable and may not show the SwiftUI window — always launch via `build/Rocky.app` for the real app behaviour.

### Sidecar venvs

Each sidecar is independent. Setup is one-shot per sidecar:

```bash
./Sidecars/brain/setup.sh                       # mlx-vlm + Qwen3-VL 4B Instruct 4-bit (~3.5 GB)
./Sidecars/face-tracker/setup.sh                # synthetic-target test scaffold (stdlib only)
./Sidecars/mlx-tts/setup.sh                     # mlx-audio 0.4.3 + Qwen3-TTS-12Hz-1.7B-Base-bf16 (~3.5 GB)
./Sidecars/robot-mic/setup.sh                   # reachy_mini SDK over WebRTC
./Sidecars/robot-camera/setup.sh                # reachy_mini SDK over WebRTC; feeds MacFaceTracker + the brain's imageProvider
```

Venvs are written to `~/Library/Application Support/Rocky/sidecars/<name>/.venv/`. AppServices auto-detects venv presence: MLX-VLM brain when `brain/.venv` exists (else LM Studio fallback), robot mic when `robot-mic/.venv` exists, Qwen3-TTS when `mlx-tts/.venv` exists. The face-tracker sidecar runs in `synthetic` mode regardless of any `ROCKY_FT_MODE` setting — its `[sam]` extras and `sam` mode are unimplemented stubs (`runner.py:92-94`); real face tracking happens Swift-side in `Sources/Perception/MacFaceTracker.swift`.

Voice cloning needs a reference clip + transcript in `~/Library/Application Support/Rocky/voice/`. The TTS backend auto-finds `reference.wav`+`reference.txt` first, then falls back to `sample.wav`+`sample.txt`. Trim the WAV to 3–10 s; longer references degrade ICL quality.

### Resetting state

```bash
# Reset all UserDefaults (settings, persona, model, mic source, TTS backend)
defaults delete ai.amplified.Rocky

# If TCC permission prompts get stuck, reset and re-prompt
tccutil reset Microphone           ai.amplified.Rocky
tccutil reset SpeechRecognition    ai.amplified.Rocky

# Nuke a sidecar venv to force a fresh setup.sh
rm -rf "$HOME/Library/Application Support/Rocky/sidecars/<name>/.venv"
```

## Conventions

- **Always use uv** for Python tooling (per global rule). All sidecar `setup.sh` files use `uv venv` + `uv pip install`.
- **Swift 6 strict concurrency** is on (`swiftLanguageModes: [.v6]`). When you hit a Sendable error, the right fix is usually an actor or a class-bound flag — not `@unchecked Sendable` and not silencing the warning.
- **`@Observable` + `@MainActor` for shared state.** `AppServices` is the canonical example.
- **`AsyncStream` for cross-actor events.** Examples: `LogBus.subscribe()`, `FaceTrackerService.targets`, `StateSubscriber.states`, `Sidecar.events`.
- **Telemetry is closed-set.** Add a case to `TelemetryEvent` (in `Sources/Telemetry/TelemetryEvent.swift`) when you need a new event type — every consumer (Logs view, dashboard cards, archive) updates from one place.
- **Tools live in the registry.** Don't sidestep `ToolRegistry`. The LLM gets the canonical schema from there; new robot capabilities = new tool entries in `AppServices.registerInitialTools()`.
- **Settings are in UserDefaults via `SettingsStore`.** Robot endpoint + LM Studio config + persona + TTS backend + mic source. Robot endpoint changes need a relaunch; LM Studio + persona hot-reload via `AppServices.applySettings()`.

## Maintain the wiki

The wiki at `docs/` is the canonical knowledge base. Anything you learn from a source, the user, or your own work goes there per `docs/WIKI.md`. The schema:

- `docs/concepts/` — cross-cutting concepts.
- `docs/reference/` — factual lookups (hardware, SDK API, motors, glossary).
- `docs/workflows/` — how-tos.
- `docs/patterns/` — reusable code patterns.
- `docs/sources/` — annotated summaries of external sources.
- `docs/decisions/` — ADRs.
- `docs/index.md` — catalog. Update on every doc add.
- `docs/log.md` — append-only chronological log. Add an entry for each non-trivial code session.

When in doubt about a wire shape or daemon behaviour, re-fetch `http://reachy-mini.local:8000/openapi.json` and update `docs/sources/daemon-openapi-*.md` — that file is dated, so a newer one supersedes the old.

## Memory rules — non-negotiable

- **Robot safety**: never stack motion-control changes. One tweak per iteration, verify calm, then next. After two failed tweaks in the same direction, stop and name the real problem; revert if needed.
- **Face tracker design**: state-driven, world-frame target, critically-damped 50 Hz controller. Do **not** regress to per-frame P-control on raw image error. The shipped implementation lives in `Sources/Perception/MacFaceTracker.swift` (Apple Vision detection on `robot-camera` frames). The Python sidecar's `controller.py` is a parallel implementation for the synthetic-target test scaffold and the same design constraints apply if you ever bring an ML detector back inside it.
- **Voice engine**: TTS uses **Qwen3-TTS-12Hz-1.7B-Base-bf16** via `mlx-audio` 0.4.3 with ICL voice cloning (Base variant — the `CustomVoice` sibling can't clone). Call `Model.generate(... stream=True, streaming_interval=0.32)` directly; `mlx_audio.tts.generate.generate_audio` consumes the iterator internally for playback side effects. Chatterbox is the legacy fallback. The `say` backend is a placeholder.
- **TTS playback target**: audio plays **only through the robot speaker** via `StreamingTTS.playToRobot` → daemon `play_sound`. The Mac-local `AVAudioEngine` path in `StreamingTTS.play(chunks:)` survives for testing but has no production caller.
- **Brain backend selection**: `BrainBackend` protocol with two implementations — `MLXVLMBrain` (default, vision-aware) and `LMStudioBrain` (text-only fallback). The active backend is set via `SettingsStore.brainBackend` (`auto` / `mlx-vlm` / `lm-studio`). The camera frame is auto-fed to the brain via `CognitionEngine.imageProvider` when `AppServices.visionEnabled` is true.
- **End-turn-after-say**: when the `say` tool fires, the cognition turn ends. Looping back to the brain after speaking causes the model to chatter with a different sentence than what was spoken, diverging chat and audio. Don't undo this without first making the bubble-vs-audio test pass.
- **Don't band-aid**: when iterative single-parameter tweaks aren't fixing a complaint, the problem is in the signal or architecture, not the tuning. Stop, diagnose, propose a real fix or revert.
