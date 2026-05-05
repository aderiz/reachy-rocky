---
title: "ADR 0001 — Target platform: Reachy Mini Wireless, Python on-robot default"
type: decision
status: accepted
last_updated: 2026-05-05
tags: [decision, platform]
---

# ADR 0001 — Target platform: Reachy Mini Wireless, Python on-robot default

## Date

2026-05-05.

## Context

User stated this project will build code specifically for **Reachy Mini Wireless**. The official `AGENTS.md` recommends defaulting to JavaScript Spaces for shareable end-user apps and falling back to Python only when on-robot compute / hardware access / offline LAN is required.

User signals that override the upstream default:

- Memory note about a state-driven face tracker with world-frame target + damped filter — implies a real-time control loop running close to the robot.
- Memory rules about robot safety and small motion changes — implies hands-on motion tuning where iteration speed matters more than browser-based distribution.
- The original directive pointed at `platforms/reachy_mini/development_workflow`, which is the on-robot Python dev guide.

## Decision

- **Default to Python apps that run on the CM4** in `/venvs/apps_venv/`.
- Use `reachy-mini-app-assistant` for scaffolding (never hand-roll structure).
- Use [Approach A](../workflows/dev-loop-wireless.md) for the dev loop (clone-on-robot + sshfs back to laptop).
- Run heavy AI / vision off-robot (laptop) when CM4 compute becomes a bottleneck. Stream commands to the daemon via SDK or REST.
- Reserve JS / WebRTC apps for when we explicitly want zero-install browser distribution. Not the default for this project.

## Consequences

- All workflow docs in `docs/workflows/` target the Wireless variant.
- Dependencies must install into `/venvs/apps_venv/` on the CM4 (Python 3.12, ARM64 wheels). Anything that requires CUDA or a heavy ML stack lives off-robot.
- App lifecycle assumptions (single app at a time, daemon-managed subprocess, SIGINT shutdown) apply throughout.
- Motion code uses the Python SDK directly, not the JS SDK / WebRTC data channel.

## See also

- [Architecture](../concepts/architecture.md)
- [App lifecycle](../concepts/app-lifecycle.md)
- [Dev loop on Wireless](../workflows/dev-loop-wireless.md)
