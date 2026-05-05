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
