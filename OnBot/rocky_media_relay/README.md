---
title: Rocky Media Relay
emoji: 🛰️
colorFrom: red
colorTo: blue
sdk: static
pinned: false
short_description: On-bot audio + video WebSocket relay for Rocky. Replaces WebRTC.
tags:
 - reachy_mini
 - reachy_mini_python_app
---

# Rocky Media Relay

A Reachy Mini app that runs **on the bot** and exposes the robot's mic
and camera over plain WebSocket. It's the bot-side half of Rocky's
v0.3 media architecture — replacing the WebRTC media client that
Rocky used to run on the Mac.

## Why

The official `media_backend="webrtc"` path is fine in theory but in
practice the WebRTC signalling drops repeatedly on WiFi, leaving the
audio track silent and the camera frozen. WebRTC over a flaky link
buys us encrypted SRTP, peer-to-peer NAT traversal, and interactive
codec negotiation — none of which Rocky needs for a LAN bot.

By running on-bot via the documented Apps system, we:

- Use the SDK's **LOCAL** media backend — IPC for video frames, direct
  GStreamer audio. No encode/decode overhead.
- Skip WebRTC entirely. Plain TCP WebSocket.
- Stay supported. This is exactly the extension pattern the docs
  describe in `SDK/apps`.

## Endpoints

Served under the app's `custom_app_url`
(default `http://0.0.0.0:8042`).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness + counters (clients, frames emitted, drops). |
| `POST` | `/control/start_recording` | Start audio capture (idempotent). |
| `POST` | `/control/stop_recording`  | Stop audio capture (idempotent). |
| `WebSocket` | `/ws/audio` | Streams `audio` + `doa` JSON envelopes. |
| `WebSocket` | `/ws/video` | Streams `frame` JSON envelopes (~15 fps, JPEG). |

### Wire format

Each WebSocket message is one JSON object, line-terminated:

```json
{"type":"audio","ts_ms":1700000000,"sr":16000,"ch":1,
 "rms":0.05,"pcm_b64":"..."}
{"type":"doa","ts_ms":1700000000,"angle_rad":1.5,"is_speech":true}
{"type":"frame","ts_ms":1700000000,"w":480,"h":270,"jpeg_b64":"..."}
```

`pcm_b64` is base64-encoded int16-LE mono PCM at 16 kHz (the
ReSpeaker's stereo output is downmixed on the bot to halve wire
bandwidth). `jpeg_b64` is a JPEG of the downscaled camera frame.

## Install

Either publish to HF and install via the bot dashboard, or develop
locally:

```bash
# Validate package layout against the official checklist.
reachy-mini-app-assistant check ./OnBot/rocky_media_relay

# Publish to HF Spaces (creates the app in the bot's dashboard).
reachy-mini-app-assistant publish ./OnBot/rocky_media_relay
```

For dev iteration: SSH into the bot, `pip install --editable` the
project from a mounted path, then start it from the daemon REST or
dashboard.

## Constraints

Per the docs:

- **Only one app can run at a time.** Starting `rocky_media_relay` will
  stop any other running app on the bot.
- Audio config (gain, AEC tuning) still has to happen on-bot via
  `audio_control_utils.py` — the daemon doesn't expose those over
  REST. We could add an endpoint here if we need it later.
