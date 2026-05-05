---
title: Media architecture
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # SDK/media-architecture
tags: [media, camera, audio, gstreamer, webrtc]
---

# Media architecture

The daemon owns the camera, mic array, and speaker via a unified GStreamer pipeline. The SDK picks a backend based on whether the client is local or remote.

## Backends

| Backend | When | What it does |
|---|---|---|
| `default` | Auto-detect | `local` if same machine, `webrtc` if remote. |
| `local` | On-CM4 / same machine | GStreamer IPC for video, direct GStreamer audio. No encode/decode overhead. |
| `webrtc` | Remote (laptop ↔ robot) | H.264 video + Opus audio over WebRTC. |
| `no_media` | Want raw access | Daemon **releases** camera/audio so you can use OpenCV / sounddevice / etc. |

```python
with ReachyMini(media_backend="default") as mini:
    frame = mini.media.get_frame()   # (H, W, 3) uint8

with ReachyMini(media_backend="no_media") as mini:
    import cv2
    cap = cv2.VideoCapture(0)        # daemon released it; we can grab directly
    ret, frame = cap.read()
```

`no_media` mode auto-reacquires the hardware on `__exit__`. You can also flip manually with `mini.release_media()` / `mini.acquire_media()` (idempotent).

## Daemon-side pipeline

The daemon starts its media pipeline automatically unless `--no-media` is passed:

1. Opens the camera (platform-aware: v4l2 / libcamera / DirectShow / AVFoundation / UDP for sim).
2. Opens the audio device (PulseAudio / ALSA / WASAPI / CoreAudio).
3. Feeds both into `webrtcsink` for remote streaming.
4. Exposes raw camera frames via local IPC (`unixfdsink` on Linux/macOS).

## Audio details

```python
mini.media.start_recording()
mini.media.start_playing()

samples = mini.media.get_audio_sample()                # (N, 2) float32 @ 16 kHz
mini.media.push_audio_sample(samples)                  # (N, 1 or 2) float32 @ 16 kHz, non-blocking
doa, voiced = mini.media.get_DoA()                     # angle in rad, bool

# always read these instead of hardcoding 16 kHz / channel count
mini.media.get_input_audio_samplerate()
mini.media.get_input_channels()
mini.media.get_output_audio_samplerate()
mini.media.get_output_channels()

mini.media.stop_recording()
mini.media.stop_playing()
```

`push_audio_sample` returns immediately; sleep `len(samples) / sample_rate` if you need to wait for playback.

After `start_recording()` + `start_playing()`, both audio devices appear **busy** to other applications. Always pair with `stop_*` (or use `media_backend="no_media"`).

## When to disable media

- Custom OpenCV pipeline (face detection model that wants direct cv2 access).
- Whisper / VAD that wants `sounddevice`.
- Profiling: avoid the GStreamer pipeline cost.

See [direct hardware pattern](../patterns/direct-hardware.md).

## See also

- [Architecture](architecture.md)
- [Direct hardware pattern](../patterns/direct-hardware.md)
- [Hardware reference](../reference/hardware.md) — camera/mic specs.
