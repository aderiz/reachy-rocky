---
title: Voice / listen pipeline
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Voice/
  - Sources/Rocky/MicCalibrationView.swift
  - Sidecars/mlx-stt/rocky_mlx_stt/runner.py
tags: [voice, audio, vad, stt, wake, address-filter]
---

# Voice / listen pipeline

The path from "the user opens their mouth" to "the brain gets a turn."
Six stages now, after the [AddressFilter](address-filter.md) rework.

```
mic ──▶ AudioRingBuffer ──▶ VAD ──▶ STT ──▶ WakeFilter ──▶ AddressFilter ──▶ Brain
(Mac /   (drop-newest        (energy   (Apple Speech /     (admit on wake-     (strict
 robot)   under saturation)   or       MLX-Whisper /       name or while       multi-signal
                              Silero)   WhisperKit)        window open)        dispatch gate)
```

The single-signal "did the VAD think there was speech?" path of v0.x
dispatched too many transcripts — Whisper hallucinations, TV in the
background, other people's conversations. The new architecture pairs
a **permissive VAD** with a **strict address filter** so spurious
input gets caught at the gate that has the full picture (segment
loudness, DoA, face presence, STT confidence).

## Stages

### 1. Mic source — `MicService` / `RobotMicService`

Two implementations behind the same shape:

- `MicService` — `AVAudioEngine` reading the Mac's default input. Used
  when `settings.micSource == "mac"`.
- `RobotMicService` — wraps the `robot-mic` sidecar (now a WebSocket
  subscriber to the on-bot relay, see
  [on-bot-media-relay](on-bot-media-relay.md)). When the source is
  `"robot"`, also exposes `lastDoaRad` + `lastDoaIsSpeech` from the
  on-bot mic array.

Both write 16 kHz mono `Float32` into one shared `AudioRingBuffer`.
Switching source mid-session requires toggling Listen off and on.

### 2. Ring buffer — `AudioRingBuffer`

Single-producer / single-consumer lock-free buffer. **Drop-newest**
when full, not drop-oldest: the oldest samples in a saturated buffer
typically contain the *start* of the user's utterance — including the
wake word — so dropping them would gut wake matching.

### 3. VAD — `EnergyVAD` (or `SileroVAD`)

Pragmatic energy detector. RMS over a sliding 30 ms frame; above
threshold for `minSpeechFrames` consecutive frames → `speechStart`;
below for `minSilenceFrames` → `speechEnd`.

VAD is intentionally **permissive** — its job is to find boundaries,
not to decide whether the speech was addressed to Rocky. False
positives (background TV passes VAD) are caught downstream by the
AddressFilter. The threshold is set by the calibration flow against
the user's **room noise only**, not motor-under-load, so it stays low
enough to catch normal speech.

### 4. STT — Apple Speech / MLX-Whisper / WhisperKit

Three engines behind a single protocol; `settings.sttEngine`
selects. MLX-Whisper is default when its sidecar venv is present.

**Whisper hallucination mitigation** (Sidecars/mlx-stt):

- `initial_prompt="A short conversation between a person and a robot
  named Rocky."` biases the language prior away from YouTube-credit
  hallucinations ("thank you for watching", "subscribe").
- Temperature fallback ladder `(0.0, 0.2, …, 1.0)` retries when
  `compression_ratio_threshold=1.8` flags a degenerate output.
- `no_speech_threshold=0.7` (tighter than upstream 0.6) drops
  low-confidence silence segments before transcription.
- Confidence-gated phrase deny-list — only drops boilerplate
  hallucinations ("thank you", "thanks for watching", "subtitles by
  the Amara.org community") when segment `no_speech_prob ≥ 0.4` *or*
  `avg_logprob ≤ -0.8`. A real "thank you" said clearly passes.
- N-gram repetition collapse for the "X. X. X. X." trap.

The transcript surface (`Transcript`) carries:

- `text`
- `confidence` (Apple Speech only — MLX paths report 1.0)
- `language`

### 5. Wake filter — `WakeFilter`

State machine: `sleeping` → `open(until:)` → back to `sleeping`.

- **Sleeping**: STT runs, but final transcripts only **admit** if they
  contain the wake word. Match is tolerant ("Rocky" / "Rockey" /
  "Rocki") with a 5-token lookahead; article-prefixed hits ("the
  rocky road") are skipped.
- **Open**: any final transcript admits. **Crucially, the window no
  longer auto-extends on `.withinWindow` hits** — only the
  AddressFilter's engagement decision extends it (see step 6). Default
  duration is **20 s**, down from 60 s — short enough that a stray
  hallucination can't perpetuate it indefinitely.
- Stop phrases ("stop listening", "go to sleep", "good night") close
  the window early.

A new `extendOnEngaged()` is called by `AppServices.handleVoice` after
the AddressFilter accepts a transcript *with* real engagement
evidence (loud + DoA on-axis + face / verb prefix). Without this gate,
hallucinations could re-extend the window every time they slipped
through.

### 6. Address filter — `AddressFilter`

The **strict** gate. Sees the transcript plus all the signals that
would let a human decide "was this addressed to me?":

- Segment peak / mean RMS (loudness over room noise)
- DoA from the on-bot mic array (robot mic only)
- Face age (was the user looking at the camera recently?)
- STT confidence
- TTS state (Rocky is speaking → echo gate)
- WakeFilter reason (wake-match vs. within-window)

Full ruleset in [address-filter](address-filter.md). The short
version: wake-name still wins (over all other gates) but only if the
segment has real audio energy; otherwise the strict ruleset requires
loudness *and* DoA on-axis (robot mic) *and* face or verb-prefix
engagement. Strict mode means "when in doubt, drop."

### 7. Coordinator — `VoiceCoordinator`

The actor that wires it all up. Three behaviours worth knowing:

- **Pre-roll buffer (180 ms / 6 frames).** Prepended to the segment
  on `speechStart` so the VAD doesn't clip the leading phoneme of
  the wake word.
- **Single-slot queued segment.** STT is single-in-flight; if a
  second segment arrives while STT is busy, it queues; a third
  replaces the queued one.
- **Force-end ≠ VAD reset.** Hitting the `maxSegmentS` cap (12 s)
  flushes but keeps `inSpeech` true — the user is still talking.

`Output.finalText` now carries `confidence`, `peakRMS`, `meanRMS`
alongside `text`/`dispatched`/`reason` so the AddressFilter has the
metadata to score without re-reading the audio.

## Calibration

`MicCalibrationView` is a four-phase capture (was three) with the
first two and last two user-gated:

1. **Room** (8 s, robot asleep, auto). HVAC + fan + computer hum.
   Used as the noise ceiling for VAD and AddressFilter.
2. **Rocky** (6 s, motors-under-load, auto). The Mac drives a 50 Hz
   parametric Lissajous head sweep (yaw amplitude ~16°, pitch
   amplitude ~6°, coprime periods 3.7 s / 2.3 s) while recording.
   Face tracking is **triple-suppressed** (`transitioningUntil` +
   `targetStreamer.setPrimaryMoveActive(true)` +
   `setFaceTrackingEnabled(false)`) so nothing fights the motion.
   Logged for diagnostic purposes but does **not** drive the VAD
   threshold — Rocky listens to the user while stationary, so the
   motor-under-load samples don't represent the floor he sees.
3. **Your voice** (12 s, user-gated). Press Start, then speak
   naturally with pauses. Used for the VAD threshold math.
4. **Address Rocky** (8 s, user-gated). Press Start, then address
   Rocky directly from where you normally sit, with "Rocky, …"
   prompts. Captures direct-address RMS *and* (on robot mic) the
   user's DoA centre + spread. Produces the four AddressFilter
   values: `addressRMSFloor`, `addressLoudnessRatio`,
   `addressUserDoaCenterRad`, `addressUserDoaToleranceRad`.

A diagnostic LogBus event fires at the end of computing so the user
can see exactly what calibration produced in the Logs view
(`room_p99`, `address_p25`, `address_p50`, computed thresholds, DoA
centre / tolerance, DoA sample count).

The flow runs `services.sleepRobot()` / `services.wakeRobot()` (not
the raw daemon endpoints) so the streamer is suppressed during the
sleep / wake transitions and Rocky reaches his home pose before
phase 2 starts.

## Telemetry

Every stage publishes to `LogBus`. New events for the listening
rework:

- `addressFilterAccept(text, score, reasons)` — dispatch decision
  with the positive gates that fired.
- `addressFilterDrop(text, score, reasons)` — drop decision with the
  negative gates. Surfaces in LogsView as
  `ignored (0.45) [low_loudness, no_face]`.

Existing events (`vadSegment`, `sttPartial`, `sttFinal`, `wakeMatch`,
`conversationWindow`) unchanged.

## Echo gate

`AppServices.handleVoice` checks `ttsBusyUntil` (+ 1.5 s tail) and
the AddressFilter explicitly drops with reason `echo_tail` when
Rocky is speaking. `StreamingTTS.playToRobot` flips
`isSpeaking = true` on the first PCM chunk; legacy non-streaming
backends stamp `ttsBusyUntil = Date() + estimatedDuration + 1.5 s`.

## TTS playback target — robot speaker only

Synthesised audio always plays through the **robot speaker**, never
the Mac. Both legacy `RobotTTS.speak` and streaming
`StreamingTTS.playToRobot` terminate at the daemon's
`/api/media/play_sound`.

## Vision integration with the brain

When the brain backend is MLX-VLM (default), the latest JPEG from
`lastCameraFrame` is passed to the model via the `imageProvider`
closure in `CognitionEngine`. Two toolbar toggles control the
camera-to-brain feed:

- **Vision** — gates the imageProvider.
- **Face tracking** — pauses / resumes `MacFaceTracker.setEnabled`
  so the head stops following faces but the camera keeps streaming.
  The tracker also auto-pauses when Rocky is asleep
  (`setSleeping(true)`) to save CPU and prevent state drift.

The face tracker's idle look-around (slow Lissajous pan when no
face is in frame) is now **opt-in** via
`SettingsStore.faceTrackerIdleSearchEnabled`, default `false`. The
previous always-on behaviour read as uncanny / attention-stealing.

## See also

- [address-filter](address-filter.md) — the strict dispatch gate.
- ADR `0003-sidecar-convention.md` — why the robot mic comes through
  a sidecar.
- [cockpit-design](cockpit-design.md) — where voice surfaces in the UI.
- [permissions-authority](permissions-authority.md) — mic + speech
  recognition permission gating.
