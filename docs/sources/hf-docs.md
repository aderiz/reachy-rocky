---
title: Hugging Face docs map
type: source
status: current
last_updated: 2026-05-05
url: https://huggingface.co/docs/reachy_mini
tags: [meta, source]
---

# Hugging Face docs map

The Hugging Face documentation site (`huggingface.co/docs/reachy_mini`). Versioned; always cross-check against `main` if behavior seems off.

## Pages ingested (2026-05-05)

| Page | What it covers | Mapped to |
|---|---|---|
| `index` | Overview, table of contents | This wiki's [README](../README.md) |
| `platforms/reachy_mini/get_started` | Wireless first-boot, WiFi, SSH credentials | [dev-loop-wireless](../workflows/dev-loop-wireless.md) (SSH bits) |
| `platforms/reachy_mini/hardware` | DOFs, motors, camera, mics, battery, CM4 | [reference/hardware](../reference/hardware.md), [reference/motors](../reference/motors.md) |
| `platforms/reachy_mini/development_workflow` | Approach A (sshfs), B (override), C (mount-and-run), rsync | [dev-loop-wireless](../workflows/dev-loop-wireless.md) |
| `SDK/installation` | uv install, venv, GStreamer (Linux), USB perms | Excerpted in [create-app](../workflows/create-app.md) |
| `SDK/quickstart` | First script, daemon check, hello-wiggle | [create-app](../workflows/create-app.md) (template) |
| `SDK/python-sdk` | `ReachyMini` class API surface | [reference/sdk-python](../reference/sdk-python.md) |
| `SDK/core-concept` | Daemon/SDK split, frames, safety, motor modes | [architecture](../concepts/architecture.md), [coordinate-frames](../concepts/coordinate-frames.md), [safety-limits](../concepts/safety-limits.md) |
| `SDK/apps` | App scaffolding, lifecycle, publishing | [app-lifecycle](../concepts/app-lifecycle.md), [create-app](../workflows/create-app.md) |
| `SDK/integration` | LLM tips, REST/WebSocket pointers | TODO — minimal (mostly pointers); will deepen after ingesting `ai-integration` skill |
| `SDK/media-architecture` | local/webrtc/no_media backends | [media-architecture](../concepts/media-architecture.md), [direct-hardware](../patterns/direct-hardware.md) |
| `troubleshooting` | Frequent issues + symptom→fix | [run-and-debug](../workflows/run-and-debug.md), [reference/motors](../reference/motors.md) |
| `sdk-tutorials` | Notebook 0 (movement), Notebook 1 (camera/audio) | TODO — ingest notebook contents |

## Pages NOT yet ingested

- `SDK/javascript-sdk` (full JS app guide). Out of scope unless we pivot.
- `platforms/reachy_mini/usage` (Reachy Mini Control GUI walkthrough).
- `platforms/reachy_mini/reflash_the_rpi_ISO` (recovery).
- `platforms/reachy_mini/install_daemon_from_branch` (testing unreleased daemon).
- `platforms/reachy_mini/media_advanced_controls` (camera/mic param tuning).
- `troubleshooting/motors_diagnosis` (deep motor fault tree).
- `troubleshooting/spherical_joints_maintenance`.
- `troubleshooting/change_mic_fpc_cable`.

## Notes on freshness

- The daemon REST schema is the source of truth — always reachable at `http://reachy-mini.local:8000/docs` when the robot is on. If the wiki conflicts with a live OpenAPI response, the live response wins.
- HF docs are versioned; `main` evolves faster than tagged versions. When a fact looks wrong, re-check on `main` before changing the wiki.
