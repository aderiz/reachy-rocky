---
title: Architecture
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
  - sources/agents-md.md
tags: [architecture, daemon, sdk]
---

# Architecture

Reachy Mini uses a **client/server split**: a long-running **daemon** owns the hardware, and **clients** (Python SDK, JS SDK, REST consumers, the desktop control app) talk to it over the network.

## On the Wireless variant

- **Daemon** runs on the onboard Raspberry Pi CM4. It boots automatically when the robot powers on. systemd unit: `reachy-mini-daemon`. Lives in `/venvs/mini_daemon/`. Owns the Dynamixel motor bus, the IMX708 camera, the ReSpeaker mic array, the speaker, and the IMU.
- **Clients** can be:
  - Python SDK on the same CM4 (`/venvs/apps_venv/`) — what installed apps run inside.
  - Python SDK on your laptop, talking to the robot over WiFi.
  - JS SDK in a browser — uses WebRTC for media, REST for control. Works from anywhere with a Hugging Face login.
  - Plain HTTP / WebSocket clients hitting the REST API directly.

## What the daemon exposes

| Surface | Purpose | URL on Wireless |
|---|---|---|
| REST | State, motor control, app management | `http://reachy-mini.local:8000/api/...` |
| OpenAPI docs | Interactive endpoint browser | `http://reachy-mini.local:8000/docs` |
| WebSocket | Real-time state stream | `ws://reachy-mini.local:8000/api/state/ws/full` |
| WebRTC | H.264 video + Opus audio (remote media) | Negotiated through the daemon |
| Local IPC | Raw frames + audio for same-machine clients | `unixfdsink` on Linux/macOS, `win32ipcvideosink` on Windows |

REST and the JS SDK's WebRTC data channel are **sibling transports** into the same `process_command()` backend on the daemon. Picking one is a deployment choice, not a functional one.

## Auto-detection in the SDK

`ReachyMini()` decides at construction:

- If the daemon's local IPC endpoint is reachable → `localhost` mode + `LOCAL` media backend (no encode/decode overhead).
- Else → `network` mode + `WEBRTC` media backend.

Override:

```python
ReachyMini(connection_mode="localhost_only" | "network",
          media_backend="default" | "local" | "webrtc" | "no_media")
```

## Where to run your code

| Code | Runs on | Why |
|---|---|---|
| Production app | CM4 (`/venvs/apps_venv/`) | Lower latency, no network dependency |
| Heavy AI / vision | Laptop | CM4 is 4 GB RAM, no GPU |
| Browser-distributed UI | Static HF Space | Zero install, shareable URL |

For this project, **default to on-robot Python apps** — see [decisions/0001](../decisions/0001-target-platform.md).

## App lifecycle from the daemon's perspective

1. Daemon starts on boot.
2. App requests come in via REST: `POST /api/apps/start-app/<name>`.
3. Daemon launches the app as a subprocess: `python -u -m your_app.main`.
4. App connects via `ReachyMini()`, runs until `stop_event.is_set()`.
5. Daemon sends `SIGINT` to stop. App returns. Daemon resets the robot pose.

Only one app runs at a time. See [App lifecycle](app-lifecycle.md) for the in-app side of the contract.

## See also

- [App lifecycle](app-lifecycle.md)
- [Media architecture](media-architecture.md)
- [Motion philosophy](motion-philosophy.md)
- [Hardware](../reference/hardware.md)
