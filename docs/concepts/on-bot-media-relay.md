---
title: On-bot media relay (rocky_media_relay)
type: concept
status: current
last_updated: 2026-05-11
sources:
  - sources/hf-docs.md   # SDK/media-architecture, platforms/.../media_advanced_controls
tags: [media, audio, video, webrtc, websocket, apps]
---

# On-bot media relay

Rocky's v0.3 media path. Audio + video capture moved from a
Mac-side WebRTC client to a bot-side Reachy Mini App that serves
the same data over plain WebSocket.

## Why the change

The documented remote pattern is:

```
Mac ──(WebRTC)──> daemon's GstMediaServer ──> bot hardware
```

That works on paper. In practice on WiFi we saw:

- `webrtcsrc Signalling error: send failed because receiver is gone`
  every few seconds.
- DTLS handshake errors (`gst_dtls_connection_process: runtime check
  failed: (!priv->bio_buffer)`).
- `Connection refused` / `SYN_SENT → RST` on the HTTP control plane.
- Mac-side `robot-mic` sidecar in a respawn loop.
- VAD on a stream with brief silent gaps over-segmenting one
  utterance into two, causing dispatch duplication. (Mitigated with
  a dedup gate, but the underlying instability remained.)

WebRTC's design assumptions — encrypted SRTP, NAT traversal, codec
renegotiation under packet loss — aren't useful for a LAN bot, and
the cost is the fragility above.

## v0.3 architecture

```
[Bot]                                [Mac]
+-----------------------------+      +----------------------------+
| daemon                      |      | Rocky.app                  |
|  └─ GstMediaServer          |      |  └─ SidecarSupervisor      |
|       (camera + audio)      |      |        ├─ robot-mic        |
|        │ LOCAL backend      |      |        │   └─ WS subscriber|
|        ▼                    | WS   |        ├─ robot-camera     |
|  └─ rocky_media_relay App   |◄────►│        │   └─ WS subscriber|
|     ├─ FastAPI on :8042     |      |        └─ ...              |
|     ├─ POST /control/...    |      |                            |
|     ├─ WS /ws/audio         |      |                            |
|     └─ WS /ws/video         |      |                            |
+-----------------------------+      +----------------------------+
```

The on-bot app uses the SDK's **LOCAL** media backend (IPC for video,
direct GStreamer for audio — no encode/decode overhead). It owns
the capture loop, JPEG-encodes camera frames at ~15 fps, downmixes
the ReSpeaker's stereo PCM to mono int16, and fans both out to
connected WebSocket subscribers.

The Mac-side `robot-mic` and `robot-camera` sidecars are thin WS
subscribers that translate the on-bot envelope into the same
SidecarHost stdout envelopes the Swift adapters already consume.
No Swift change.

## Trade-offs vs WebRTC

| | WebRTC | Relay |
|---|---|---|
| Network reliability on LAN | flaky (DTLS, signalling) | TCP — stable |
| Latency overhead | encode/decode pipeline | base64 over WS (~1 ms) |
| Encryption | yes (SRTP) | no (HTTP/WS plaintext on LAN) |
| Encoding | OPUS / H264 negotiated | int16 PCM + JPEG |
| App slot | none consumed | consumes the bot's single-app slot |
| Doc support | officially documented | officially documented (Apps system) |

Rocky doesn't need encrypted media on a LAN. The single-app
constraint means the bot can't run other apps while
`rocky_media_relay` is active — fine for Rocky's use case where
it's the only thing running.

## Wire format

Each WS message is one JSON object, newline-terminated:

```json
{"type":"audio","ts_ms":1700000000,"sr":16000,"ch":1,"rms":0.05,"pcm_b64":"..."}
{"type":"doa","ts_ms":1700000000,"angle_rad":1.5,"is_speech":true}
{"type":"frame","ts_ms":1700000000,"w":480,"h":270,"jpeg_b64":"..."}
{"type":"hello","sr":16000,"ch":1,"video_fps_cap":15,"build":"rocky-media-relay/0.1"}
```

`audio` and `doa` envelopes arrive on `/ws/audio`. `frame` envelopes
arrive on `/ws/video`. `hello` is sent once when a client connects.

## Reliability

Each WS subscriber has its own bounded queue (200 messages). On
overflow the producer drops oldest — newer frames always preferred
over stale. The subscriber-side sidecars reconnect with
exponential-ish backoff (1 → 2 → 5 → 10 s).

If the bot or the app go down, the Mac sidecars stay in the
respawn-free reconnect loop without restarting; only when they
ultimately exit (stdin EOF, daemon shutdown signal) does the
supervisor consider it a fault.

## See also

- `docs/workflows/deploy-media-relay.md` — install / iterate flow
- `OnBot/rocky_media_relay/` — bot app source
- `Sidecars/robot-mic/rocky_robot_mic/runner.py` — Mac subscriber
- `Sidecars/robot-camera/rocky_robot_camera/runner.py` — Mac subscriber
