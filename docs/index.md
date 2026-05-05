---
title: Wiki Index
type: index
last_updated: 2026-05-05
---

# Index

The catalog of every page in the wiki.

## Concepts

- [Architecture](concepts/architecture.md) — daemon/SDK split, where code runs, REST + WebRTC transports.
- [Motion philosophy](concepts/motion-philosophy.md) — `goto_target` for gestures, `set_target` in a control loop.
- [Coordinate frames](concepts/coordinate-frames.md) — head frame, world frame, units (mm, deg, rad).
- [Safety limits](concepts/safety-limits.md) — joint ranges, head/body yaw delta, auto-clamping.
- [Media architecture](concepts/media-architecture.md) — `local`/`webrtc`/`no_media` backends, GStreamer/IPC.
- [App lifecycle](concepts/app-lifecycle.md) — entry points, single-app constraint, SIGINT shutdown.

## Reference

- [Hardware](reference/hardware.md) — physical specs of the Wireless variant.
- [Python SDK](reference/sdk-python.md) — `ReachyMini` class API surface.
- [Motors](reference/motors.md) — IDs, names, ranges, common faults.
- [Glossary](reference/glossary.md) — terms.

## Workflows

- [Dev loop on Wireless](workflows/dev-loop-wireless.md) — sshfs Approach A (recommended).
- [Create an app](workflows/create-app.md) — `reachy-mini-app-assistant` CLI.
- [Run and debug](workflows/run-and-debug.md) — daemon logs, `journalctl`, common pitfalls.

## Patterns

- [Control loop](patterns/control-loop.md) — single 100 Hz loop, pose computation per tick.
- [Recorded moves](patterns/recorded-moves.md) — record/replay + Pollen emotions library.
- [Direct hardware access](patterns/direct-hardware.md) — `media_backend="no_media"` + OpenCV/sounddevice.

## Sources

- [AGENTS.md](sources/agents-md.md) — canonical AI-agent guide for the Reachy Mini repo.
- [HF Docs map](sources/hf-docs.md) — pages we've ingested from huggingface.co/docs/reachy_mini.

## Decisions

- [0001 — Target platform](decisions/0001-target-platform.md) — Wireless on-robot Python is the default.

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
