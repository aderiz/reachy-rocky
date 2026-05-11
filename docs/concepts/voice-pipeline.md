---
title: Voice / listen pipeline
type: concept
status: current
last_updated: 2026-05-08
sources:
  - Sources/Voice/
  - Sources/Rocky/MicCalibrationView.swift
tags: [voice, audio, vad, stt, wake]
---

# Voice / listen pipeline

The path from "the user opens their mouth" to "the LLM gets a turn." Five
stages, each with its own type, all linked by `VoiceCoordinator` so they
can be tested independently.

```
mic source ──▶ AudioRingBuffer ──▶ EnergyVAD ──▶ AppleSpeechSTT ──▶ WakeFilter ──▶ CognitionEngine
   (Mac /         (drop-newest        (live-       (per-call           (state           (LLM turn)
    robot)         under              tunable      retry, locale       machine,
                   saturation)        threshold)   robust)             60 s window)
```

## Stages

### 1. Mic source — `MicService` / `RobotMicService`

Two implementations behind the same shape:

- `MicService` — `AVAudioEngine` reading the Mac's default input. Used
  when `settings.micSource == "mac"`.
- `RobotMicService` — wraps the `robot-mic` sidecar (Python +
  `reachy_mini` SDK over WebRTC) and feeds frames into the same buffer.
  Default when the sidecar venv exists at
  `~/Library/Application Support/Rocky/sidecars/robot-mic/.venv/`.

Both write 16 kHz mono `Float32` into one shared `AudioRingBuffer`.
Switching source mid-session requires toggling Listen off and on — the
audio chain is bound at start time.

### 2. Ring buffer — `AudioRingBuffer`

Single-producer / single-consumer lock-free buffer. **Drop-newest** when
full, not drop-oldest: the oldest samples in a saturated buffer typically
contain the *start* of the user's utterance — including the wake word
"Rocky" — so dropping them would gut wake matching. The cost is a
truncated tail of an over-long utterance, which is far less destructive.

`droppedSamples` is exposed; the dashboard can surface the drop rate.

### 3. VAD — `EnergyVAD`

Pragmatic energy-based detector. RMS over a sliding 30 ms frame; above
`config.rmsThreshold` for `minSpeechFrames` consecutive frames →
`speechStart`. Below for `minSilenceFrames` → `speechEnd`.

Defaults (tuned across sessions):

| Field              | Default | Notes |
|--------------------|---------|-------|
| `rmsThreshold`     | 0.008   | Lower than the original 0.015 (was missing quiet/distant speech). User-calibrated via the Settings sheet — see below. |
| `minSpeechFrames`  | 3       | ~90 ms of confirmed speech. |
| `minSilenceFrames` | 22      | ~660 ms — enough to span natural mid-sentence pauses without ending the segment. The previous 14 (~420 ms) was clipping turns. |

Threshold is **publicly mutable**: `EnergyVAD.config.rmsThreshold` can
be reassigned without resetting the frame counters, so a re-tune
mid-utterance just shifts the cutoff for subsequent frames. This is
how live calibration applies without restarting the listen pipeline.

The `VAD` protocol exists so a `SileroVAD` (CoreML) drop-in can replace
the energy detector behind the same interface. Currently energy-only.

### 4. STT — `AppleSpeechSTT`

`SFSpeechRecognizer` actor with two pieces of robustness baked in:

- **Recogniser is `var`, not `let`.** `SFSpeechRecognizer(locale:)` may
  return `nil` on a fresh install if Speech is still downloading the
  locale's offline model in the background. Each `transcribe` call
  retries `ensureRecognizer()` so a first-launch user with `en-GB`
  (or any on-demand locale) gets STT as soon as the assets land.
- **`requiresOnDeviceRecognition` evaluated per-call.** The flag flips
  when the offline model finishes downloading; setting it true with
  the model not yet available silently fails.

The "No speech detected" `kAFAssistantErrorDomain code 1110` error is
treated as a benign empty transcript, not a thrown error.

### 5. Wake filter — `WakeFilter`

State machine: `sleeping` → `open(until: Date)` → back to `sleeping`.

- **Sleeping**: STT runs, but final transcripts only dispatch if they
  contain the wake word ("Rocky" / "Rockey" / "Rocki"). The match is
  tolerant of punctuation and uses a 5-token lookahead so embedded
  wake-words ("Rocky, what time is it") still dispatch the whole
  transcript. Article-prefixed hits ("the rocky road") are skipped via
  a `continue`.
- **Open**: any final transcript dispatches; the deadline auto-extends
  (60 s default) on each turn. Stop phrases ("stop listening", "go to
  sleep") close the window early; `manual` close also fires from the
  Settings toggle.

Wake-state changes surface as `Output.windowOpened(until:)` /
`.windowClosed(reason:)` events on the coordinator's `outputs` stream;
`AppServices` mirrors them into `conversationOpenUntil` for the UI.

### 6. Coordinator — `VoiceCoordinator`

The actor that wires it all up. Three behaviours worth knowing:

- **Pre-roll buffer (180 ms / 6 frames).** While the VAD is in `silence`,
  every incoming chunk is also kept in a rolling pre-roll. On
  `speechStart`, the pre-roll is prepended to `pendingSegment` *before*
  the chunk that triggered the transition. Without this, the first
  90–180 ms of speech is clipped (the VAD needs `minSpeechFrames` of
  loud audio to confirm speech, and that audio was being thrown away).
  Symptom this fixed: "Rocky" → "ocky" → STT hears "okay" / "hockey",
  wake filter misses.
- **Single-slot queued segment.** STT is single-in-flight (Apple
  Speech doesn't pipeline a second request well). Old behaviour: drop
  the new segment if STT is busy. New: keep one queued segment;
  replace it if a third arrives. So a fast back-and-forth ("Rocky" →
  "what time is it" 400 ms later) still gets both segments
  transcribed and dispatched in order.
- **Force-end ≠ VAD reset.** When `pendingSegment` exceeds the
  `maxSegmentS` cap (12 s default), the segment is flushed but the
  VAD's `inSpeech` latch is **kept true** — the user is still talking,
  the cap is an artificial slice, and resetting the VAD would drop the
  next ~90 ms of speech to re-confirm.

## Calibration

Settings → Voice → "Sensitivity" exposes:

- A live RMS readout (mirrors `services.lastMicRMS`).
- A manual threshold slider (range 0.001…0.05, step 0.001).
- A **Calibrate…** button that opens `MicCalibrationView`.

Calibration is a two-phase capture:

1. **Quiet (2 s).** "Don't speak. Rocky is sampling room noise." Polls
   `lastMicRMS` at 20 Hz; collects `noiseSamples`.
2. **Speak (3 s).** "Speak normally." Same poll; collects
   `speechSamples`.

Threshold formula: midpoint between `noise_max × 1.5` (headroom over
peak room noise) and `speech_p25 × 0.5` (half the 25th-percentile
speech RMS, well below any normal word), clamped to `[0.001, 0.05]`.
The full math is in `MicCalibrationView.computeThreshold`.

The result is persisted as `settings.micVADThreshold` and applied
**live** via `voice.setVADThreshold(_)` — no Listen-toggle required.
Subsequent launches seed the VAD from the persisted value (see
`AppServices.init` where the initial `EnergyVAD.Config` is built).

The sheet auto-enables Listen on entry (so RMS samples flow) and
restores the prior state on dismiss, so calibration is non-disruptive
to the user's mic-on/mic-off preference.

## Telemetry

Every stage publishes to `LogBus`:

- `vad_segment` — start/end of a detected speech burst.
- `stt_final` — final transcript text + total latency (ms).
- `wake_match` — wake-word hit with the matched name and the full
  transcript.
- `conv_window` — `opened` / `extended` / `closed(reason)` transitions.
- `error(scope: "stt", ...)` — transcription failures (recoverable).

The Activity tab of the inspector renders these rows in time order; the
Hero card surfaces the latest.

## Echo gate

When Rocky speaks, his TTS bleeds into his own mic and the STT pipeline
will dutifully transcribe it. Two gates running side by side:

- **Streaming path (default since v0.2 with Qwen3-TTS).**
  `StreamingTTS.playToRobot` flips `isSpeaking = true` on the **first
  PCM chunk** emitted by the sidecar (echo gate engages as soon as
  synthesis starts, not when the robot begins playing), and flips back
  off after `durationS + sttPostRollS` (default 0.5 s) has elapsed.
  This is the ground-truth signal the persona's M6 plan asked for —
  `ttsBusyUntil` is updated from `isSpeakingStream` rather than guessed.
- **Legacy non-streaming path (Chatterbox or any backend reporting
  `streams: false`).** `AppServices.say` stamps `ttsBusyUntil` to
  `Date() + estimated_speech_duration + 1.5s_tail` before the
  `robotTTS.speak` await begins, then refines after `speak` returns
  with the real `durationS + 1.5s`. The voice-output handler discards
  finals whose timestamp falls inside the window.

In both cases the 0.5–1.5 s tail covers the fall-off of the speaker
after the audio frame itself ends. Without this, Rocky frequently
dispatched fragments of his own last reply as the user's next input.

## TTS playback target — robot speaker only

Synthesised audio always plays through the **robot speaker**, never
the Mac. Both the legacy `RobotTTS.speak` (full-WAV → upload →
`play_sound`) and the streaming `speakStreaming` (PCM chunks
accumulated by `StreamingTTS.playToRobot` → single WAV → upload →
`play_sound`) terminate at the daemon's `/api/media/play_sound`
endpoint. The `AVAudioEngine`-backed Mac-local path in
`StreamingTTS.play(chunks:)` still exists for testing but has no
production caller.

The trade-off is that chunked streaming through the robot is not
incremental — we wait for synthesis to finish before sending the
WAV — because the daemon's `play_sound` is not a streaming endpoint.
First-chunk-on-Mac (97 ms target) becomes first-audio-on-robot
(synthesis time + upload, currently ~3 s with ICL cloning on a 6 s
reference). Trueing this up requires either chunked play_sound on
the daemon side or a parallel WebRTC audio stream, neither of which
exists yet.

## Vision integration with the brain

When the brain backend is MLX-VLM (the v0.2 default), the latest
JPEG from `lastCameraFrame` is passed to the model at the start of
every chat turn via the `imageProvider` closure in `CognitionEngine`.
Rocky can answer questions about visible content ("what am I
holding?", "how do I look?") because the model gets the pixels with
the user's text in the same prompt. The persona (v6+) carries a
VISION section with worked examples so the model actually uses the
frame instead of falling back to "Rocky not know".

Two toolbar toggles control the camera-to-brain feed:

- **Vision** (`eye.fill` / `eye.slash.fill`) — gates the
  `imageProvider`. Off = text-only conversation, camera sidecar
  keeps running for the Vision card and face tracker.
- **Face tracking** (`face.smiling.inverse` / `face.dashed`) — pauses
  / resumes `MacFaceTracker.setEnabled` so the head stops following
  faces but the camera keeps streaming.

## See also

- ADR `0003-sidecar-convention.md` — why the robot mic comes through
  a sidecar.
- `concepts/cockpit-design.md` — where voice surfaces in the UI.
- `concepts/permissions-authority.md` — mic + speech recognition
  permission gating.
