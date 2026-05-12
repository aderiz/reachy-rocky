---
title: "ADR 0006 — On-bot media relay replaces WebRTC"
type: decision
status: accepted
last_updated: 2026-05-12
tags: [decision, media, audio, video, webrtc, websocket, apps, battery]
---

# ADR 0006 — On-bot media relay replaces WebRTC

## Date

2026-05-11 (decision + implementation). Backfilled as an ADR on
2026-05-12.

## Context

Rocky's v0.1 and v0.2 took audio + video from the bot to the Mac via
the daemon's official `media_backend="webrtc"` path. The design
assumes WebRTC's transport — SRTP-encrypted RTP over UDP with DTLS
handshake, signalling over WebSocket — is appropriate for the
Mac-to-bot link.

On the WiFi link in practice that path failed every few minutes:

- `webrtcsrc Signalling error: send failed because receiver is gone`
  every few seconds.
- DTLS handshake errors:
  `gst_dtls_connection_process: runtime check failed:
  (!priv->bio_buffer)`.
- `Connection refused` / `SYN_SENT → RST` on the HTTP control plane.
- Mac-side `robot-mic` sidecar in a respawn loop.
- VAD on a stream with brief silent gaps over-segmenting one
  utterance into two, causing dispatch duplication (mitigated with a
  dedup gate but the underlying instability remained).

Multiple debugging sessions confirmed that none of these are
configurable away; they're inherent to WebRTC over a flaky WiFi link
between two endpoints that don't actually need WebRTC's guarantees
(no NAT to traverse, no untrusted peer to encrypt against, no need
for codec renegotiation under packet loss).

Separately, the daemon's REST API doesn't expose battery / power
state at all (the bot has no fuel-gauge IC — see ADR's sister doc
[power monitoring](../reference/power-monitoring.md)), but we knew
we'd want that data on the Mac for the power chip. Whatever path we
chose for media needed to be flexible enough to carry other
bot-derived telemetry without re-architecting.

## Decision

**Run a bot-side Reachy Mini App (`rocky_media_relay`) that serves
audio + video over plain WebSocket, plus a small REST surface for
state the daemon doesn't expose.**

Specifically:

1. Author `OnBot/rocky_media_relay/` as a `ReachyMiniApp` subclass.
   It runs in the bot's existing `apps_venv`, subclasses
   `ReachyMiniApp`, and uses the SDK's **LOCAL** media backend (IPC
   for video frames, direct GStreamer for audio — no encode/decode
   round-trip).
2. Mount a FastAPI app at the relay's `custom_app_url`
   (`http://0.0.0.0:8042`) exposing:
   - `WS /ws/audio` — newline-terminated JSON envelopes for PCM +
     DoA frames.
   - `WS /ws/video` — JSON envelopes for downscaled JPEG frames at
     ~15 fps.
   - `POST /control/{start,stop}_recording` — idempotent audio
     gating.
   - `GET /health` — liveness + counters + cached battery block.
   - `GET /battery` — supply-voltage / power-state snapshot derived
     from the Dynamixel motors' `PRESENT_INPUT_VOLTAGE` register (the
     bot has no fuel-gauge IC; this is the workaround).
3. The Mac-side `robot-mic` and `robot-camera` sidecars become thin
   WebSocket subscribers that translate the relay's envelope into
   the same SidecarHost stdout shape the Swift adapters already
   consume. No Swift change required for media; new Swift
   `BatteryService` actor consumes `/battery`.
4. Auto-start from the Mac: `AppServices.ensureRelayAppRunning()`
   probes `/api/apps/current-app-status` at launch and starts the
   relay if nothing is running (the daemon doesn't persist the
   running-app across reboots).
5. Camera-feed lifecycle binds to Rocky's sleep state: when Rocky
   sleeps, the `robot-camera` sidecar disconnects its `/ws/video`
   subscription; the relay sees `len(video_clients) == 0` and stops
   JPEG-encoding on the bot. Mic stays subscribed even when sleeping
   so wake-on-name keeps working.

## Alternatives considered

### A. Stay on WebRTC + harden the GStreamer pipeline

Tried first. Added DTLS-error suppression, signalling-channel
backoff, codec preferences. None of it stopped the failures. The
DTLS errors come from inside the Rust webrtc plugin and the
signalling failures are bidirectional. Treating WebRTC as a
debugging problem turned out to be the wrong frame.

### B. Add a daemon-side endpoint

Modify the daemon to expose audio + video over a non-WebRTC path
(REST stream, raw TCP, etc.). Would require Pollen-side changes
since the daemon is upstream code; we'd be running a fork. Also
doesn't solve the "where do we put battery state" question.

### C. Bot-side script over SSH

Run a Python script over an SSH session that pipes audio+video to
the Mac. Would work but bypasses the daemon's app system, leaves
audio configuration (gain, AEC) un-integrated, and the bot has no
service supervisor for it.

### D. Bot-side Reachy Mini App over WebSocket (chosen)

The Apps system is the **documented extension pattern**. Apps run
in the bot's `apps_venv` with full SDK access, get supervised by the
daemon, can be installed via the dashboard / HF / direct deploy. A
WebSocket fan-out is well-understood and trivially debuggable. The
single-app-at-a-time constraint applies — but Rocky is the only
thing wanting to run anyway.

## Trade-offs

| | WebRTC | Bot-side WS relay |
|---|---|---|
| LAN reliability | flaky (DTLS, signalling) | TCP — stable |
| Latency overhead | encode → SRTP → decode | base64 over WS (~1 ms) |
| Encryption | yes (SRTP) | no (plaintext on LAN) |
| Encoding | OPUS / H.264 negotiated | int16 PCM + JPEG |
| App slot consumed | none | bot's single app slot |
| Doc support | officially documented | officially documented (Apps system) |
| Carries non-media data | no | yes (`/battery`, `/health`) |

Plaintext is acceptable on a LAN-only deployment; Rocky is single-
user and doesn't traverse untrusted networks. The single-app-slot
cost is acceptable because the bot otherwise has nothing to run.

## Consequences

**Positive**
- Audio + video stream is rock-solid over WiFi — no DTLS errors, no
  signalling drops, no respawn loops.
- The relay became the natural place to expose other bot-derived
  state that the daemon doesn't carry — first `/battery` (see ADR's
  sister doc), but the surface generalises to anything else we
  discover the daemon doesn't expose.
- Mac sidecars dropped the heavy `reachy_mini` SDK dependency;
  pyprojects now pull only `websockets` (plus `numpy` for the mic's
  RMS).
- The bot CPU savings from the LOCAL backend (no encode/decode
  round-trip) made the bot cooler, which secondarily reduced fan
  noise.

**Negative**
- The bot can't run any other Reachy Mini App while
  `rocky_media_relay` is active. This is the price of the
  single-app-slot constraint. Fine for Rocky's use case where the
  relay IS the app.
- Plaintext WS over LAN. Not encrypted. Acceptable for a LAN-only
  deployment but to be re-evaluated if Rocky ever needs to traverse
  untrusted networks.
- No automatic recovery if the bot reboots — handled via
  `AppServices.ensureRelayAppRunning()` from the Mac side, which is
  fine but is a Mac-side responsibility now.
- We carry the maintenance cost of an on-bot deploy pipeline. See
  `docs/workflows/deploy-media-relay.md` + `scripts/deploy-media-
  relay.sh`.

## Implementation references

- `OnBot/rocky_media_relay/rocky_media_relay/main.py` — the app
  itself.
- `OnBot/rocky_media_relay/README.md` — quick-start + endpoint
  catalog.
- `Sidecars/robot-mic/rocky_robot_mic/runner.py` + `Sidecars/robot-
  camera/rocky_robot_camera/runner.py` — Mac-side WS subscribers.
- `Sources/Rocky/AppServices.swift:ensureRelayAppRunning` — Mac-side
  auto-start probe.
- `Sources/Rocky/BatteryService.swift` — Mac-side `/battery`
  consumer.
- `scripts/deploy-media-relay.sh` — dev iteration loop on the bot.

## See also

- [On-bot media relay](../concepts/on-bot-media-relay.md) — fuller
  concept doc covering architecture + wire format + reliability.
- [Power monitoring](../reference/power-monitoring.md) — the
  Dynamixel reg-144 workaround surfaced through this relay.
- [Deploy the on-bot media relay](../workflows/deploy-media-relay.md)
  — install / iterate flow.
- ADR [0003 — Sidecar convention](0003-sidecar-convention.md) —
  the Mac-side process model these WebSocket subscribers conform to.
