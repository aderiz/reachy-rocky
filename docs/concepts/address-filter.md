---
title: AddressFilter — strict "spoken-to-me" gate
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Voice/AddressFilter.swift
  - Sources/Rocky/AppServices.swift
  - Sources/Rocky/MicCalibrationView.swift
tags: [voice, address-filter, dispatch-gate, hallucination]
---

# AddressFilter

The post-STT pre-brain dispatch gate. Decides "was this transcript
addressed to Rocky?" using multiple signals fused into a strict
ruleset. Sits between `WakeFilter` (which decides whether a
transcript should even be considered) and the brain dispatch.

## Why it exists

Without this filter, every transcript that passed VAD and the wake
filter went straight to the brain. That's the wrong question to
ask — VAD just detects audio energy. It accepts background TV,
other people's conversations, Whisper hallucinations, anything with
speech-like energy.

A human listens differently. They respond when *addressed* — sound
coming directly from a person facing them, at conversational volume.
Background noise gets filtered automatically by the brain's
attention system. The AddressFilter encodes that heuristic
explicitly.

## Signals it consults

`AddressFilter.Signals` is a snapshot of everything available at
the moment of dispatch. All reads happen at the call site
(`AppServices.handleVoice`) so the actor doesn't reach into the
rest of the app:

| Signal | Source | Notes |
|---|---|---|
| `text` | STT transcript | Already passed STT. |
| `sttConfidence` | `Transcript.confidence` | Apple Speech reports per-utterance; MLX paths always report 1.0. |
| `segmentPeakRMS` | `VoiceCoordinator.computeRMS` | Loudest 30 ms window in the captured segment. |
| `segmentMeanRMS` | Same | Reserved; not currently scored. |
| `roomNoiseCeiling` | Settings, from calibration | Room P99 RMS (motors idle). |
| `doaRad` | `RobotMicService.lastDoaRad` | Robot mic only; `nil` on Mac mic. |
| `doaIsSpeech` | `RobotMicService.lastDoaIsSpeech` | Robot-side VAD flag. |
| `faceVisibleAgeS` | `AppServices.lastFaceDetectionAt` | Seconds since last face detection. |
| `wakeReason` | `WakeFilter.decide` | `.wakeMatch(name:)` or `.withinWindow`. |
| `ttsActive` | `ttsBusyUntil` | Includes 1.5 s tail. |
| `micSource` | Settings | `"mac"` or `"robot"`. |

## Decision logic

Priority order. First match wins.

1. **Master switch.** When `addressFilterEnabled == false`, the
   filter is transparent — accepts everything. Returns
   `reasons: ["filter_disabled"]`.

2. **Echo tail.** If Rocky is speaking (or within 1.5 s of
   finishing), drop. Tagged `echo_tail`.

3. **Wake-name match.** If `wakeReason == .wakeMatch`, dispatch —
   the user explicitly addressed Rocky. **But only when the audio
   has real energy**: require `segmentPeakRMS ≥ rmsFloor`. Whisper
   sometimes hallucinates "rocky" / "rockey" / "rocki" on silent
   segments; without the loudness gate, a hallucination would wake
   the bot from sleep with nobody having said anything. A real
   user shouting "Rocky!" easily clears the floor. Hallucinated
   wakes drop with `wake_hallucination, low_loudness`.

4. **STT confidence floor.** Drop if `sttConfidence <
   minSttConfidence` (default 0.35), unless transcript is in the
   short bypass set (`yes`, `no`, `stop`, `wait`, `cancel`). Tagged
   `low_confidence`.

5. **Junk phrase deny-list.** Drop if normalised text is in the
   junk set (`thank you`, `thanks`, `you`, `bye`, `okay`, `.`,
   `…`). This catches Apple Speech's known boilerplate outputs that
   ship at confidence 1.0 so the confidence gate doesn't catch
   them. Tagged `junk_phrase`.

6. **Strict gate — ALL of:**
   - **Loudness over background**: `segmentPeakRMS ≥ rmsFloor` AND
     `segmentPeakRMS / roomNoiseCeiling ≥ loudnessRatio` (default
     4×). Negative tag: `low_loudness`.
   - **Direction (robot mic only)**: `|doaRad − userDoaCenterRad| ≤
     userDoaToleranceRad` (default ±0.45 rad ≈ ±26°). Skipped on
     Mac mic. Negative tag: `doa_off_axis`.
   - **Engagement**: at least one of
     - `faceVisibleAgeS ≤ faceEngageWindowS` (default 3 s) →
       `face`
     - DoA on-axis AND `doaIsSpeech == true` → `doa_is_speech`
     - First token of normalised text in
       `verbPrefixes` (default `what/where/when/why/how/tell/show/
       do/does/can/could/is/are/play/stop/set/turn`) →
       `verb_prefix`
   - Negative tag if none fire: `no_engagement`.

7. **Otherwise — drop**, with the combined negative tags so the
   user can see in the Logs view exactly why the transcript was
   ignored.

## Strict-mode semantics

When signals are ambiguous (Mac mic with camera off, plain phrase
that doesn't start with a verb prefix), the default is **drop**.
The wake-word bypass (rule 3) keeps Rocky reachable in those
conditions — the user just has to say "Rocky" first.

## Configuration

All values live in `SettingsStore` and hot-apply through
`AppServices.applyAddressFilterCalibration(...)`:

| Setting | Default | Source |
|---|---|---|
| `addressFilterEnabled` | `true` | Master switch. |
| `addressMinSttConfidence` | `0.35` | STT confidence floor. |
| `addressRMSFloor` | `0.012` | Below this is "too quiet to be direct address." Set by calibration phase 4. |
| `addressLoudnessRatio` | `4.0` | `peakRMS / roomNoiseCeiling` must clear this. Set by calibration. |
| `addressUserDoaCenterRad` | `0` | User's typical DoA from the bot (0 = facing). Set by calibration phase 4 (robot mic). |
| `addressUserDoaToleranceRad` | `0.45` | Half-cone width around the centre. |
| `addressFaceEngageWindowS` | `3.0` | How recently a face must have been seen. |
| `convoWindowS` | `20.0` | WakeFilter conversation window. |
| `addressJunkPhrases` | `["thank you", "thanks", "you", "bye", "okay", ".", "…"]` | Drop list. |
| `addressVerbPrefixes` | `["what", "where", "when", …]` | Engagement-via-prefix list. |

## Telemetry

Two `TelemetryEvent` cases:

- `addressFilterAccept(text, score, reasons)` — dispatched with the
  positive gates that fired (e.g. `["wake"]` or `["loud", "face",
  "doa_on_axis"]`).
- `addressFilterDrop(text, score, reasons)` — dropped with negative
  gates (e.g. `["low_loudness", "no_face"]` or
  `["wake_hallucination", "low_loudness"]`).

LogsView renders both inline as
`addressed (0.95) [loud, face]` / `ignored (0.20) [low_loudness]`.

## Tests

`Tests/VoiceTests/AddressFilterTests.swift` covers every gate as a
table-driven case:

- Wake-name overrides other gates *when loud enough*.
- Wake-name on near-silence drops as `wake_hallucination`.
- Junk phrase drops at any confidence.
- Low STT confidence drops.
- Short bypass tokens pass confidence.
- Loud + on-axis + face → dispatch.
- Loud + off-axis (robot mic) → drop.
- Quiet → drop.
- Mac mic + face + verb prefix → dispatch.
- Mac mic + no face + verb prefix → dispatch.
- Mac mic + no face + plain phrase → drop.
- `enabled == false` makes the filter transparent.

13 tests total.

## See also

- [voice-pipeline](voice-pipeline.md) — where this fits in the
  end-to-end path.
- `Sources/Voice/AddressFilter.swift` — the actor itself.
- `Sources/Rocky/AppServices.swift:handleVoice` — the call site
  that snapshots signals + interprets the decision (including
  `extendOnEngaged`).
