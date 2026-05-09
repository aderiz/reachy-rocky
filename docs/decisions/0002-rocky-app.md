---
title: "ADR 0002 — Rocky as a macOS-native nervous system"
type: decision
status: accepted
last_updated: 2026-05-05
tags: [decision, rocky, architecture]
---

# ADR 0002 — Rocky as a macOS-native nervous system

## Date

2026-05-05.

## Context

The user wants Rocky — a "virtual coworker with a body" — built as a native
macOS Swift app rather than a Python on-robot app (the upstream `AGENTS.md`
default).

Memory inputs that shaped the decision:

- Project memory at planning time assumed a SAM-3.1-based face tracker
  ported into the Rocky tree. The state-driven, world-frame, critically-
  damped 50 Hz design held; the **detector** changed at implementation
  time — the shipped tracker is `Sources/Perception/MacFaceTracker.swift`
  using Apple Vision (`VNDetectFaceRectanglesRequest`) on JPEG frames
  from the `robot-camera` sidecar. Off-robot compute on Apple Silicon
  is faster than the CM4 either way.
- Robot safety memory: small motion changes only.
- "Don't band-aid" memory: name root causes; revert if needed.

The user also specified hard architectural constraints:

- All external processes must run under one **Sidecar** convention (see ADR
  0003). Swift never `Process.run`s ad-hoc.
- The robot speaker is the primary voice output ("colleague in the room").
- Always-on STT + name filter for wake (not push-to-talk, not a separate
  wake-word model).
- Face-tracker sidecar grabs frames via `reachy_mini` SDK; Swift gets
  downsampled JPEGs over IPC, never raw WebRTC.
- LM Studio is the brain (OpenAI-compatible localhost endpoint).

## Decision

Build Rocky as a native macOS SwiftUI app with the layered architecture in
[`concepts/rocky-architecture.md`](../concepts/rocky-architecture.md):

- 8 Swift Package targets: `Rocky` (executable) + `RockyKit`, `Telemetry`,
  `SidecarHost`, `RobotLink`, `Vision`, `Voice`, `Cognition`.
- `WindowGroup` (Dashboard / Status / Logs / Settings) +
  `MenuBarExtra` for calm-tech presence.
- Robot transport is REST + WebSocket. No WebRTC stack in Swift.
- Heavy AI (face tracker, TTS) lives in Python sidecars under the
  `SidecarHost` contract.
- LM Studio is hot-reloadable via `SettingsStore`; persona is a
  user-editable system prompt.
- Apple's `SFSpeechRecognizer` is the default STT (built-in, on-device,
  zero deps); the `STTEngine` protocol is the seam for swapping in
  WhisperKit later.

## Consequences

- macOS 15 minimum (Swift 6 strict concurrency, modern SwiftUI).
- App target is non-sandboxed (necessary to spawn arbitrary Python sidecars).
  Direct download / DMG distribution; no MAS.
- Information density on the dashboard is high; `LogBus` + `LogsView` lets the
  user audit anything the system did.
- Each sidecar adds a manifest, a `runner.py`, and a thin Swift adapter. Adding
  a new modality (e.g., emotion classifier) is a constrained, well-understood
  task.
- Robot endpoint changes require relaunch (sidecars and sockets hold the
  original); LM Studio + persona changes are hot-reloadable.

## See also

- [Rocky architecture](../concepts/rocky-architecture.md)
- [Sidecar convention](../concepts/sidecar-convention.md)
- ADR [0003 — Sidecar convention](0003-sidecar-convention.md)
- [Daemon OpenAPI snapshot](../sources/daemon-openapi-1.7.1.md)
