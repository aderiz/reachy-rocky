# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**Rocky** — a native macOS app that acts as the *nervous system* for a **Reachy Mini Wireless** robot. Cognition (LM Studio brain), perception (face tracking), audition (mic + STT), voice (cloned-voice TTS via Chatterbox FP16), and observability all run on the Mac; the robot is reduced to a clean network endpoint over REST + WebSocket.

- **OS target**: macOS 15+, Apple Silicon. Swift 6, SwiftUI.
- **Bundle ID**: `ai.amplified.Rocky` (drives TCC, `defaults read/write`, Console.app filtering).
- **Robot variant**: Wireless (CM4 onboard, WiFi). Daemon at `http://reachy-mini.local:8000` — live OpenAPI snapshot in `docs/sources/daemon-openapi-1.7.1.md`.
- **LLM**: LM Studio (OpenAI-compatible at `localhost:1234/v1`). Default model: `gemma-4-e4b-it-mlx`.

The implementation plan lives at `~/.claude/plans/i-d-like-this-to-swirling-octopus.md`. Always read it for the rationale behind a structural choice before changing one.

## Big-picture architecture

Three independent loops, each with its own cadence and ownership. They never call each other directly — cross-loop signalling happens via the `LogBus` actor or `@Observable` state on `AppServices` (the main-actor singleton). See `docs/concepts/rocky-architecture.md` for the diagram.

1. **Robot state loop** (~10 Hz). `StateSubscriber` reads the daemon's `WS /api/state/ws/full` → mirrors into `AppServices.lastRobotState` → `MotionCard` redraws.
2. **Face-tracker target loop** (50 Hz). `face-tracker` Python sidecar emits `target` events → `FaceTrackerService` → `FaceTargetBridge` → `TargetStreamer` → `POST /api/move/set_target`.
3. **Voice / brain / TTS loop** (event-driven). Mic → VAD → STT → `WakeFilter` → `CognitionEngine` → `ToolRegistry` (which may invoke `RobotTTS.speak` → `mlx-tts` sidecar → `MediaClient` upload + `play_sound`).

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

# Full test suite (53 tests across 17 suites; integration tests spawn echo + face-tracker sidecars)
swift test

# Filter to one suite
swift test --filter "Sidecar host"
swift test --filter "WakeFilter"

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
./Sidecars/face-tracker/setup.sh                # synthetic detector deps (stdlib + numpy)
FT_EXTRAS=sam,robot ./Sidecars/face-tracker/setup.sh   # real SAM 3.1 + reachy_mini SDK
./Sidecars/mlx-tts/setup.sh                     # `say` backend (no deps)
FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh       # Chatterbox FP16 via mlx-audio
./Sidecars/robot-mic/setup.sh                   # reachy_mini SDK over WebRTC
```

Venvs are written to `~/Library/Application Support/Rocky/sidecars/<name>/.venv/`. AppServices auto-detects venv presence to pick defaults: robot mic when `robot-mic/.venv` exists, Chatterbox TTS when `mlx-tts/.venv` exists. **The face-tracker sidecar defaults to `synthetic` mode** — set `ROCKY_FT_MODE=sam` in its manifest (or env) to switch to SAM 3.1 once the `[sam]` extras are installed.

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
- **Face tracker design**: state-driven, world-frame target, critically-damped 50 Hz controller. Do **not** regress to per-frame P-control on raw image error. The validated implementation lives in `Sidecars/face-tracker/rocky_face_tracker/controller.py`.
- **Voice engine**: TTS uses **Chatterbox FP16** (via `mlx-audio`), not F5-TTS-MLX. The `say` backend is a placeholder.
- **Don't band-aid**: when iterative single-parameter tweaks aren't fixing a complaint, the problem is in the signal or architecture, not the tuning. Stop, diagnose, propose a real fix or revert.
