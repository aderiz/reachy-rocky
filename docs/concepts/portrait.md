---
title: Portrait composition
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Rocky/Cockpit/PortraitView.swift
  - Sources/Rocky/UI/BatteryChip.swift
  - Sources/Rocky/UI/ReachyMiniAvatar.swift
tags: [ui, portrait, cockpit, swiftui]
---

# Portrait composition

The portrait is the cockpit's left column — Rocky's "presence"
surface. Per `cockpit-design.md`, it carries:

- The 3D avatar (rendered from live `lastRobotState`).
- A floating **SensesChip** in the top-left corner — combined live
  camera frame + audio waveform + STT partial.
- A floating **PowerChipOverlay** in the top-right corner — iOS-style
  battery pill driven by [power monitoring](../reference/power-monitoring.md).
- A name plate at the bottom — "Rocky" title + a single sentence of
  presence ("Listening to Ade.", "Asleep — say his name to wake.").
- A **WakeSleepSwitch** inline with the name plate — an iOS-styled
  sliding toggle.

The whole column sits on a backdrop gradient that **adapts to the
system colour scheme**.

## Layout

```
┌─────────────────────────────────────────────┐
│ ┌──────────┐                  ┌──────────┐  │
│ │ Senses   │     Avatar       │  78% 🔌  │  │  ← floating chips
│ │ chip     │   (3D head,      └──────────┘  │
│ │ (video + │    antennas,                   │
│ │  audio)  │    body)                       │
│ └──────────┘                                │
│                                             │
│   Rocky                            ●━━━○    │  ← name plate + toggle
│   Listening to Ade.                         │
└─────────────────────────────────────────────┘
```

## Components

### `ReachyMiniAvatar` + `backdrop(for:)`

The avatar is a SceneKit-rendered 3D head; it's transparent so the
backdrop gradient shows through and antennas silhouette against the
lighter crown.

**`ReachyMiniAvatar.backdrop(for: ColorScheme)`** is the single
source of truth for the column's background gradient. It returns a
different `LinearGradient` for each system mode:

- Dark mode: slate (`#33373D`) → near-black (`#0A0D12`).
- Light mode: soft slate (`#F0F2F7`) → mid-grey (`#BCC7D6`).

In both cases the bottom stop is the darker of the two so the name
plate + toggle land on quieter territory. `PortraitView` reads
`@Environment(\.colorScheme)` and passes it through, so toggling
macOS Appearance re-tints live.

### `SensesChip`

Rendered overlay on the top-left of the avatar. Combines:

1. Live JPEG from the robot camera (`services.lastCameraFrame`).
2. A gradient scrim along the bottom of the chip darkens the
   video so the audio overlay reads against any lighting.
3. Inside the scrim: a scrolling waveform sampled at ~30 Hz from
   `services.lastMicRMS`, with the rolling STT partial below it.
4. A resize grip in the bottom-right corner — drag to scale. Size
   is persisted in `SettingsStore.visionChipWidth/Height`.

The waveform is RMS-coloured (cyan → green → amber → red) with an
age-fade so older samples are dimmer.

### `PowerChipOverlay` + `BatteryChip`

`PowerChipOverlay` reads `services.latestBattery` and shows the
shared `BatteryChip` only when there's a useful signal (i.e., the
relay is reachable and reports `present: true`). The chip itself is
an iOS-style horizontal pill:

- Filled left-to-right proportional to `percent`.
- White thumb-less drawing inside the pill (it's the pill itself
  that fills, not a thumb).
- Charging-bolt overlay when `power_source == "dc"`.
- Percent (or `DC`) readout to the right of the pill in
  `rounded.monospacedDigit`.

Tier colours: green ≥30 % (or DC), amber 15–29 %, red <15 %. See
[power monitoring](../reference/power-monitoring.md) for the
underlying signal.

### Name plate + `WakeSleepSwitch`

Bottom of the column. Left side: "Rocky" title + presence sentence
computed from `services.rockyState`. Right side: the sliding wake
toggle.

**`WakeSleepSwitch`** is a custom switch (not `Toggle(.switch)`) so
it can carry sun/moon iconography on the track ends. Convention:

- **Awake = "on"**: thumb on the **right** (iOS standard), green
  track (`#34C758`), sun glyph in the thumb.
- **Asleep = "off"**: thumb on the **left**, near-black track
  (`#1C1C20`), moon glyph in the thumb.
- **Waking**: muted + disabled until the wake transition completes.

The dark slate glyph reads cleanly against the white thumb in both
states. End-cap glyphs on the opposite end fade to 0 — the thumb
always sits over the icon representing the *current* state.

⏎ toggles wake/sleep. The action calls `services.wakeRobot()` /
`services.sleepRobot()` so the streamer is properly suppressed
during the transition (the raw daemon endpoints don't do that —
see [voice-pipeline](voice-pipeline.md) §calibration for the same
gotcha).

## State sources (single source of truth)

| Element | Reads from |
|---|---|
| Avatar geometry | `services.lastRobotState` |
| Senses chip — video | `services.lastCameraFrame` |
| Senses chip — audio | `services.lastMicRMS`, `services.lastTranscript` |
| Power chip | `services.latestBattery` (via `BatteryService`) |
| Name plate | `services.rockyState`, `services.lastFaceDetection?.identity` |
| Wake toggle | `services.rockyState` |

## See also

- [Cockpit design](cockpit-design.md) — full window layout, where
  the portrait sits in the larger composition.
- [Power monitoring](../reference/power-monitoring.md) — the data
  the power chip displays.
- [Voice / listen pipeline](voice-pipeline.md) — what feeds the
  senses chip's waveform + transcript.
