---
title: Glossary
type: reference
status: current
last_updated: 2026-05-05
tags: [glossary]
---

# Glossary

| Term | Meaning |
|---|---|
| **Daemon** | Long-running process on the CM4 that owns hardware and serves REST/WebRTC. systemd unit: `reachy-mini-daemon`. |
| **SDK** | The `reachy_mini` Python package. Talks to the daemon. |
| **CM4** | Raspberry Pi Compute Module 4 — the onboard computer in the Wireless. |
| **Stewart platform** | The 6-bar parallel mechanism that gives the head 6 DOF. Motors 11–16. |
| **DoA** | Direction of Arrival — sound source angle estimated by the mic array. |
| **Compliant / gravity compensation** | Soft motor mode where the head can be moved by hand and stays put. Used for teach-by-demo. |
| **Wakeup / sleep** | Motor enable / disable cycle. Asleep robots silently ignore motion commands. |
| **Recorded move** | Pre-baked motion sequence loaded from a Hugging Face dataset (e.g. `pollen-robotics/reachy-mini-emotions-library`). |
| **Primary / secondary moves** | Pose-fusion pattern: primary = mutually exclusive (emotions, dances), secondary = additive offsets (face tracking, breathing). |
| **`apps_venv`** | `/venvs/apps_venv/` — shared Python virtualenv on the CM4 for installed apps. |
| **`mini_daemon` venv** | `/venvs/mini_daemon/` — separate venv for the daemon itself. |
| **App store** | Hugging Face Spaces tagged `reachy_mini_python_app`, surfaced inside Reachy Mini Control. |
| **WebRTC media backend** | Remote-client mode where the daemon streams H.264 video + Opus audio over WebRTC. |
| **Local media backend** | Same-machine mode using GStreamer IPC for raw frames + direct device audio. |
| **`no_media`** | Backend that releases camera/audio so external libraries (OpenCV, sounddevice) can grab them directly. |
| **`reachy-mini-app-assistant`** | CLI for creating, validating, and publishing apps. |
| **`reachyminios_check`** | Diagnostic script on the CM4 that verifies the robot setup. |
| **Reachy Mini Control** | Pollen's desktop app for connecting to the robot, browsing/installing apps, and tweaking settings. |
| **mDNS / `reachy-mini.local`** | Multicast DNS discovery name. Works on most home networks; can fail on guest / hotel / conference WiFi. |
| **Placo** | Inverse-kinematics backend that supports `enable_gravity_compensation`. |

## See also

- [Architecture](../concepts/architecture.md)
- [Hardware](hardware.md)
