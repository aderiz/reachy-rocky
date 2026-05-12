---
title: TTS engines + voice cloning
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sidecars/mlx-tts/rocky_tts/runner.py
  - Sidecars/mlx-tts/rocky_tts/backends.py
  - Sidecars/mlx-tts/rocky_tts/chatterbox_backend.py
  - Sidecars/mlx-tts/rocky_tts/qwen3_tts_backend.py
  - Sidecars/mlx-tts/rocky_tts/fish_tts_backend.py
tags: [tts, voice-cloning, mlx-audio, chatterbox, qwen3, fish, sidecar]
---

# TTS engines + voice cloning

Rocky speaks through the **`mlx-tts`** sidecar (`Sidecars/mlx-tts/`)
— a `mlx-audio` 0.4.3 wrapper that supports several voice-cloning
backends behind one Swift-facing protocol. The user picks the
backend via `settings.ttsBackend`.

## Backends + benchmarks

Real-time factor (RTF) on M-series Macs against a 6-second
reference clip. Lower = faster. Source: voice cloning benchmark
run on 2026-05-09:

| Backend | RTF | Streaming | Quality | Notes |
|---|---|---|---|---|
| `chatterbox` | **0.15×** | yes | strong | 8-bit MLX quantisation; default since `7d463aa`. |
| `chatterbox-turbo` | 0.25× | yes | strong | 6-bit MLX, faster but degraded ICL. |
| `qwen3-tts` | 0.36× | **no** | strongest | 12 Hz / 1.7B Base, ICL cloning; non-streaming since `585dea9`. |
| `higgs-audio-v2` | 0.66× | no | good | Q8. |
| `fish-audio-s2` | 1.08–1.59× | **no** | near-RT | Decoder calls a closure during synthesis (`fish_speech.py:953`) so streaming isn't usefully separable. |
| `sesame-csm` | 1.3× | no | good | Conversational tone; older arch. |
| `say` | n/a | no | OS-default | Placeholder — Apple `NSSpeechSynthesizer`, no clone. |

`chatterbox` is the shipped default because it wins on RTF AND has
a clean cloning path that just works. The picker in
`Settings → Voice` exposes all of them; the user can swap mid-
session and the runner re-loads the backend.

## RPC surface

The sidecar (`runner.py:46-128`) speaks the standard line-JSON
wire format. Methods:

| Method | Purpose |
|---|---|
| `synthesize(text)` | Full-WAV synthesis; returns base64 PCM + duration_ms. The path Chatterbox / Qwen3-TTS use today. |
| `synthesize_stream(text)` | Chunked PCM stream via `event: chunk` envelopes for `supports_streaming = true` backends. Currently only Chatterbox advertises support. |
| `set_voice_ref(audio_b64, transcript)` | Hot-swap the reference clip. Re-loads the cached `mx.array`. Backend must support it (Chatterbox, Qwen3-TTS do). |
| `health()` | `{ok, backend, voice_ref_id, streams}`. The `streams` boolean is read from `backend.supports_streaming` and tells AppServices which path to invoke. |
| `warm_up()` | Forces the model into memory + runs a 0.5 s synthesis so the first user-facing call doesn't pay the load cost. |

## Voice cloning — reference-clip layout

Each backend reads from
`~/Library/Application Support/Rocky/voice/` (see the
[application-support-layout](../reference/application-support-layout.md)
reference). Lookup order in `chatterbox_backend.py:54-65` and
`qwen3_tts_backend.py:44-52`:

1. `reference.wav` + `reference.txt` — preferred.
2. `sample.wav` + `sample.txt` — fallback.

The `.txt` file must contain the **exact transcript** of the audio.
ICL voice cloning conditions the speaker embedding on the
text-audio alignment; a mismatched transcript produces drift.
This caught us out on the v0.2 Qwen3-TTS path until commit `585dea9`
fixed the auto-find logic to honour the transcript pair.

Recommended clip parameters:

- **Duration**: 3–10 seconds. Longer clips degrade ICL
  conditioning.
- **Content**: Natural conversational speech. Avoid singing,
  whispering, or unusual prosody unless that's the target voice.
- **Channels**: Mono.
- **Sample rate**: Any — backends resample internally.
- **Format**: WAV, PCM, 16-bit, uncompressed.

The reference is loaded once into a cached `mx.array` per backend
(`chatterbox_backend.py:_load_ref_array`, similar in Qwen3) — not
re-decoded per call. `set_voice_ref` invalidates the cache.

## Streaming vs. non-streaming — why Qwen3 switched

Qwen3-TTS-12Hz was originally invoked via `Model.generate(stream=True,
streaming_interval=0.32)`. Side-by-side A/B with greedy non-streaming
revealed:

- Same length output.
- 97.8 % of samples differed between the two paths.
- 0.78 cross-correlation — audibly different speaker.

The streaming decoder's pooling order differs subtly from the
non-streaming path, and the result is a drifted clone. Commit
`585dea9` switched Qwen3-TTS to `stream=False` and accepted the
worse first-packet latency in exchange for clone fidelity. The
backend now sets `supports_streaming = False` and AppServices
takes the legacy non-streaming path through `RobotTTS.speak` for
it.

Chatterbox 8-bit's streaming decoder is bit-identical between the
two paths, so it remains the streaming default — chunk-stream into
the `StreamingTTS` player + echo gate.

## Generated-audio path

Both paths terminate at the daemon's `/api/media/play_sound`. The
Mac-local `AVAudioEngine` path in `StreamingTTS.play(chunks:)`
survives for testing but has **no production caller**. Rocky's
voice always plays through the **robot speaker** so the user
associates the audio with the embodied robot, not the laptop.

The trade-off: first-chunk-on-Mac is ~97 ms (Chatterbox synthesis
+ play_sound upload), but first-audio-on-robot is currently ~3 s
because we wait for synthesis to finish before sending the WAV —
the daemon's `play_sound` is not a streaming endpoint. Closing
that gap requires daemon-side chunked playback or a parallel
WebRTC audio stream.

## Pronunciation testing

Settings → Faces → "Add face" has a play-button next to the
"Says" field that calls `services.robotTTS.speak(text)` directly,
so the user can hear how Rocky will pronounce a name (or a
phonetic spelling like `shi-vawn`) before committing the
enrollment. The button's state mirrors `pronouncing` and shows
`speaker.wave.2.fill` with a pulse effect during playback. See
`EnrollFaceForm` in `Sources/Rocky/SettingsView.swift`.

## See also

- [Voice / listen pipeline](voice-pipeline.md) — where the TTS
  output lands (echo gate, busy window).
- [Application Support layout](../reference/application-support-layout.md)
  — voice clone file placement.
- [On-bot media relay](on-bot-media-relay.md) — the
  `/api/media/play_sound` path through which audio reaches the
  robot speaker.
