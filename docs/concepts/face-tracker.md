---
title: Face tracker + face library
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Perception/MacFaceTracker.swift
  - Sources/Perception/FaceLibrary.swift
  - Sources/Rocky/SettingsView.swift (EnrollFaceForm)
tags: [perception, face-tracking, vision, antennas, apple-vision]
---

# Face tracker + face library

The face-tracking subsystem is **Swift-side**: Apple's Vision
framework runs `VNDetectFaceRectanglesRequest` on every camera
frame, a critically-damped controller emits world-frame head + body
targets at 50 Hz, and an enrolled-face feature-print store provides
identity matching. The Python `face-tracker` sidecar is a synthetic
test scaffold and not the live path on this branch.

The actor: `MacFaceTracker` (`Sources/Perception/MacFaceTracker.swift:20`).

## Data flow

```
RobotCameraService.Frame ──▶ ingestFrame(_:)
                            │  (skip when sleeping)
                            ▼
                    Vision face detection (15 fps)
                            │
                            ▼
                    EMA smoother (α = 0.25)
                            │
                            ▼
                    decayIfIdle (opt-in Lissajous)
                            │
                            ▼
              critically-damped controller (50 Hz)
                            │
                            ▼
                  TargetStreamer.send(...)   ──▶ daemon
```

`MacFaceTracker.start()` kicks off the 50 Hz `commandLoop`. Frames
arrive via `ingestFrame(_:)` from
`AppServices.robotCamera.frames` whenever the on-bot relay's
`/ws/video` produces a JPEG.

## Stages

### Detection

Each ingested frame is JPEG-decoded → `CGImage` → fed to
`Vision.FaceObservation` async API. The largest bounding box wins
(closest face). Centroid is projected into camera-frame yaw +
pitch, then to world-frame using the damper's current position as
baseline (`MacFaceTracker.swift:414+`).

When `services.faceTrackingEnabled` is false OR
`MacFaceTracker.setSleeping(true)` has been called (Rocky asleep),
`ingestFrame` returns immediately — no Vision pass, no target
generation. Saves ~10 ms per frame and prevents EMA drift
overnight from stray detections.

### EMA smoother

α = 0.25 — heavy bias toward the new detection (75% old + 25% new
isn't actually how it reads; α = 0.25 means the new sample
contributes 25%). Hides micro-jitter in Apple Vision's bbox
centroids without lagging real movement.

### Idle look-around (opt-in)

`decayIfIdle(dt:)` (`MacFaceTracker.swift:586+`) — if no face has
been detected for `config.idleTimeoutS` (1.5 s default), drive the
EMA on a slow Lissajous in yaw + pitch (~17° / ~3° at 30 s / 18 s
periods). **Off by default** as of commit `0906fd2` — the always-on
behaviour read as uncanny. Toggle via
`settings.faceTrackerIdleSearchEnabled`. Gated additionally on
`sleeping`, so a stray detection can't start the bot scanning
mid-night.

### Critically-damped controller

50 Hz semi-implicit Euler step on a critically-damped 2nd-order
system:

```
v ← v + dt · (−2ω·v − ω² · (x − target))
x ← x + dt · v
```

ω = `config.damperOmega` (default 4.0 rad/s). Speed-capped at
`config.maxSpeedRadPerS` (1.2 rad/s = 69°/s) so any single-tick
target snap is bounded. Body follows head at 35% scale on a
slower damper (ω = 2.5).

Output → `TargetStreamer.send(...)` which pushes
`set_target_head_pose` + `target_antennas` to the daemon at 50 Hz.

## Antenna twitch — independent of head

The antennas have their own 50 Hz Poisson-triggered twitch
generator (`tickAntennas` in `MacFaceTracker.swift:614+`). Each
antenna runs an independent trigger every tick with probability
`dt · antennaTwitchRatePerS` (default 0.10/s ≈ one twitch every
10 s per antenna). On trigger:

1. Pick a random delta in `[-amplitude, +amplitude]`
   (`config.antennaTwitchAmplitude = 0.12 rad`).
2. Pick a random hold duration in `[minHold, maxHold]`
   (0.18–0.55 s).
3. Ease from rest to (rest + delta) with τ-in.
4. After hold expires, ease back to rest with τ-out (longer than
   in, so the return reads as a settle rather than a snap).

**Rest position is ±0.1745 rad (~10°), not 0.** The antenna motors
mechanically resonate at vertical — Pollen's daemon comments this
explicitly. See [motors reference](../reference/motors.md). Don't
ever command 0 rad.

Output is quantised to a 0.02 rad grid before going on the wire so
the 50 Hz stream emits the *same value* for the entire hold phase
rather than per-frame floating-point drift.

## Identity matching — `FaceLibrary`

The detection bbox is cropped + fed to
`VNGenerateImageFeaturePrintRequest` to produce a feature-print
vector. `FaceLibrary` (`Sources/Perception/FaceLibrary.swift:20`)
holds enrolled persons:

```swift
struct Person {
    let id: UUID
    let displayName: String
    let pronunciation: String
    let featurePrints: [Data]
    let enrolledAt: Date
}
```

For each detection, the tracker queries `FaceLibrary.match(_:)`
which finds the nearest-neighbour feature-print across every
enrolled person and returns a `Match` if the distance is below
`settings.faceMatchThreshold` (default 1.0). The match's
`Person.displayName` becomes the identity carried on the
`Detection`.

Storage: `~/Library/Application Support/Rocky/face-library.json`
(JSON). See [application-support-layout](../reference/application-support-layout.md).

## Enrollment

`EnrollFaceForm` in `Sources/Rocky/SettingsView.swift` is the user
flow:

1. Enter `Name` (display name).
2. (Optional) Enter `Says` — phonetic spelling for TTS. The play
   button to the right plays the pronunciation through Rocky's
   TTS so the user can test it before committing. See
   [tts-engines](tts-engines.md).
3. Add photos — either via `NSOpenPanel` ("Choose photos…") or
   grab the latest camera frame ("Use current frame").
4. Submit. `services.enrollFace(name:pronunciation:photoJPEGs:)`
   runs each photo through Vision feature-print + writes the
   `Person` record to `face-library.json`.

## Telemetry

The tracker emits to `LogBus`:

- `.faceDetection(bbox:confidence:promptId:)` — every detection,
  with `promptId` carrying the identity name when known.
- `.faceTarget(yawRad:pitchRad:decayActive:)` — every 50 Hz
  controller tick.

`MomentFeed` coalesces consecutive `.faceDetection` of the same
person into a single `recognised(person:)` moment so the Inspector
→ Activity tab doesn't drown in detections.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `faceTrackingEnabled` | `true` | Mac-side master switch; pauses the tracker's streamer push (detection still runs unless sleeping). |
| `faceTrackerIdleSearchEnabled` | `false` | Whether `decayIfIdle` runs the Lissajous pan. Off by default — read as uncanny on. |
| `faceMatchThreshold` | `1.0` | Apple Vision feature-print distance ceiling. Smaller = stricter. |

## See also

- [Portrait composition](portrait.md) — how face state surfaces
  on the avatar.
- [Voice / listen pipeline](voice-pipeline.md) — face presence
  is one of the AddressFilter's engagement signals.
- [Motors reference](../reference/motors.md) — antenna anti-
  vibration constraint that drove the ±10° rest position.
- [Application Support layout](../reference/application-support-layout.md)
  — where `face-library.json` lives on disk.
