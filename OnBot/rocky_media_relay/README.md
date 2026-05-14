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

A Reachy Mini app that runs **on the bot** and is Rocky's bot-side
conduit for everything the daemon doesn't expose itself:

- Audio + video capture, fanned out to remote subscribers over plain
  WebSocket (replaces WebRTC).
- A `/battery` REST endpoint that reads supply voltage out of the
  Dynamixel motors and reports power state (the Wireless has no
  fuel-gauge IC; this is the workaround).

It's a normal Reachy Mini App — runs in the bot's `apps_venv`,
subclasses `ReachyMiniApp`, integrates with the daemon's Apps
system, follows the single-app-at-a-time rule.

## Why this exists

### Media: skipping WebRTC

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

### Battery: working around the missing fuel gauge

The Wireless has a LiFePO4 battery + BMS but the BMS is **purely
protective** — no SOC measurement, no charging-status output, no
i²c-readable register. The daemon's REST surface has no `/battery`
endpoint, the kernel's `/sys/class/power_supply/` is empty, and
GPIO 23 (which *looks* like a charger-detect pin) is in fact the
shutdown push-button.

What IS readable: every Dynamixel motor continuously samples its own
supply rail and exposes it via **register 144**
(`PRESENT_INPUT_VOLTAGE`). The relay sends a Protocol-2.0 READ
packet to each motor through the daemon's existing raw-packet
WebSocket, takes the median, maps it through a LiFePO4 voltage
curve, and surfaces the result on `/battery`. See
`docs/reference/power-monitoring.md` in the repo wiki for the full
analysis (empirical thresholds, voltage→SOC anchors, why we route
through here instead of polling motors from the Mac directly).

## Endpoints

Served under the app's `custom_app_url`
(default `http://0.0.0.0:8042`).

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/health` | Liveness + counters (clients, frames emitted, drops, video FPS cap). Includes a cached `battery` block. |
| `GET`  | `/battery` | Battery snapshot — see schema below. Cached 2 s. |
| `POST` | `/control/start_recording` | Begin audio capture (idempotent). |
| `POST` | `/control/stop_recording`  | Stop audio capture (idempotent). |
| `WebSocket` | `/ws/audio` | Streams `audio` + `doa` JSON envelopes. |
| `WebSocket` | `/ws/video` | Streams `frame` JSON envelopes (~15 fps, JPEG). |
| `GET` | `/api/motion/health` | On-bot motion-guard config snapshot (thresholds, allowlist). |
| `POST` | `/api/motion/set_target` | Slew-rate-limited set_target → forwards to daemon. |
| `POST` | `/api/motion/goto` | Velocity + duration floor + single-in-flight + yaw-delta gate; forwards to daemon. |
| `POST` | `/api/motion/play/{move}` | Built-in moves (wake_up, goto_sleep). Forwards to daemon. |
| `POST` | `/api/motion/play/{dataset}/{move}` | Emotion library moves; rejected unless `force=true` or `move` is in the shelf-safe allowlist. |
| `POST` | `/api/motion/set_motor_mode` | `{"mode": "enabled" \| "disabled" \| "gravity_compensation"}` → daemon. |
| `POST` | `/api/motion/stop_move` | Stop in-flight move → daemon. |

The `/api/motion/*` endpoints are Rocky's **on-bot motion guard** — they enforce slew, velocity, duration, single-in-flight, shelf-safe allowlist, and the Pollen-documented 65° head-body yaw delta cap before forwarding to the local daemon at `127.0.0.1:8000/api/move/*`. The Mac's `RobotLinkClient` rewrites all motion-bearing calls to these endpoints when `SettingsStore.onBotMotionGuardEnabled` is true (default). State reads still go to the daemon directly — they're read-only.

For true uncircumventability, firewall the daemon to localhost-only so nothing else can hit `:8000` from outside the bot:

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow 8042/tcp
sudo ufw allow from 127.0.0.1 to any port 8000
sudo ufw enable
```

### `/battery` schema

```json
{
  "present": true,
  "percent": 78,
  "status": "Charging",
  "charging": true,
  "plugged_in": true,
  "voltage_v": 7.3,
  "current_a": null,
  "temperature_c": null,
  "source": "dynamixel:reg144",
  "motor_samples_v": [7.3, 7.3, 7.2, 7.3, 7.3, 7.3, 7.3, 7.3, 7.3],
  "power_source": "dc"
}
```

`current_a` and `temperature_c` are reserved — the BMS doesn't
expose them. `source` indicates how the values were derived
(`dynamixel:reg144` for the motor-voltage path).

Empirical thresholds:

| Source | Median voltage |
|---|---|
| DC plugged in | 7.30 V (charger regulating) |
| Battery, LiFePO4 nominal plateau | 6.40–6.50 V |
| Battery, near cutoff | <5.9 V |

The 0.8 V gap between DC and battery is unambiguous; a 6.9 V
threshold separates them.

### Media wire format

Each WebSocket message is one JSON object, line-terminated:

```json
{"type":"audio","ts_ms":1700000000,"sr":16000,"ch":1,
 "rms":0.05,"pcm_b64":"..."}
{"type":"doa","ts_ms":1700000000,"angle_rad":1.5,"is_speech":true}
{"type":"frame","ts_ms":1700000000,"w":480,"h":270,"jpeg_b64":"..."}
{"type":"hello","sr":16000,"ch":1,"video_fps_cap":15,
 "build":"rocky-media-relay/0.1"}
```

`pcm_b64` is base64-encoded int16-LE mono PCM at 16 kHz (the
ReSpeaker's stereo output is downmixed on the bot to halve wire
bandwidth). `jpeg_b64` is a JPEG of the downscaled (~480 wide)
camera frame.

`hello` is sent once per client on connect.

## Camera sleep — driven by the Mac

The video producer is gated on `len(state.video_clients) > 0`. When
the Mac-side `robot-camera` sidecar disconnects (which happens when
Rocky goes to sleep), `video_clients` drops to zero and the bot
stops JPEG-encoding entirely. The encoder idles, CPU returns to the
audio-only path. On wake, the Mac re-subscribes and encoding
resumes.

The **microphone stays subscribed even when Rocky is asleep** —
needed for wake-on-name. Closing the audio WS would mean the bot
couldn't hear "Rocky" while asleep.

## Auto-start from the Mac

The daemon doesn't persist "which app was last running" across
reboots — after a bot power-cycle, `current-app-status` returns
`null` and any Mac-side WebSocket subscriber spins in its reconnect
loop forever. Rocky's `AppServices.ensureRelayAppRunning()` closes
that gap at app launch: wait for the daemon's HTTP endpoint to come
up, then `POST /api/apps/start-app/rocky_media_relay` if nothing
else is running. Runs once per Mac launch.

## Install + dev iteration

Either publish to HF and install via the bot dashboard, or develop
locally:

```bash
# Validate package layout against the official checklist.
reachy-mini-app-assistant check ./OnBot/rocky_media_relay

# Publish to HF Spaces (creates the app in the bot's dashboard).
reachy-mini-app-assistant publish ./OnBot/rocky_media_relay
```

For fast dev iteration, the repo ships
`scripts/deploy-media-relay.sh` — rsyncs the package onto the bot
and `uv pip install --editable`s it into `/venvs/apps_venv/`. Restart
the running app via `POST /api/apps/restart-current-app` to pick up
changes.

## Constraints

Per the docs:

- **Only one app can run at a time.** Starting `rocky_media_relay`
  will stop any other running app on the bot.
- Audio config (gain, AEC tuning) still has to happen on-bot via
  `audio_control_utils.py` — the daemon doesn't expose those over
  REST. We could add an endpoint here if we need it later.

## See also

In the main Rocky repo:

- `docs/concepts/on-bot-media-relay.md` — fuller wiki page covering
  the architecture + trade-offs vs WebRTC.
- `docs/reference/power-monitoring.md` — the Dynamixel reg-144
  workaround, why it works, LiFePO4 SOC mapping.
- `docs/workflows/deploy-media-relay.md` — install / iterate flow.
- `Sidecars/robot-mic/` + `Sidecars/robot-camera/` — the Mac-side
  WebSocket subscribers.
