---
title: Daemon OpenAPI snapshot — v1.7.1
type: source
status: current
last_updated: 2026-05-05
url: http://reachy-mini.local:8000/openapi.json
tags: [daemon, rest, schema]
---

# Daemon OpenAPI snapshot — v1.7.1

Captured live from this user's robot on 2026-05-05. **79 endpoints**. Robot at `192.168.1.173`. Daemon reports `mean_control_loop_frequency: 49.6 Hz`, `period ≈ 20 ms`.

This page records the deltas from what we'd assumed, so the wiki and code stay honest about the wire shape.

## Confirmed endpoints (already in our model)

- `POST /api/move/set_target` ✓
- `POST /api/move/goto` ✓
- `POST /api/move/stop` ✓
- `POST /api/move/play/wake_up` ✓
- `POST /api/move/play/goto_sleep` ✓
- `GET /api/state/full` ✓
- `GET /api/state/present_head_pose|present_body_yaw|present_antenna_joint_positions|doa` ✓
- `GET /api/daemon/status` ✓
- `POST /api/motors/set_mode/{mode}` ✓ (`enabled` / `disabled` / `gravity_compensation`)
- `GET /api/motors/status` ✓
- `WS /api/state/ws/full` ✓ — emits ~10 Hz, same JSON shape as `/api/state/full`. Not advertised in OpenAPI; verified by direct HTTP-Upgrade.

## Wire-shape corrections (where we had guessed wrong)

### `POST /api/move/set_target` — `FullBodyTarget`

Field names use a **`target_` prefix**, NOT bare `head` / `antennas` / `body_yaw`.

```jsonc
{
  "target_head_pose": {           // either XYZRPYPose or Matrix4x4Pose
    "x": 0.0, "y": 0.0, "z": 0.0,
    "roll": 0.0, "pitch": 0.0, "yaw": 0.0
  },
  "target_antennas": [right_rad, left_rad],
  "target_body_yaw": 0.0,
  "timestamp": "2026-05-05T12:21:21.738006Z"
}
```

`Matrix4x4Pose` form: `{"m": [16 numbers row-major]}` (note the wrapper key `m`, not bare array).

### `POST /api/move/goto` — `GotoModelRequest`

Fields are **bare** (`head_pose` / `antennas` / `body_yaw`), not `target_*`. `interpolation` enum: `linear`, `minjerk`, `ease_in_out`, `cartoon`.

```jsonc
{
  "head_pose": { "x":0,"y":0,"z":0,"roll":0,"pitch":0,"yaw":0 },
  "antennas": [0.0, 0.0],
  "body_yaw": 0.0,
  "duration": 1.0,
  "interpolation": "minjerk"
}
```

### `GET /api/state/full` — live response

Field names: **`control_mode`** (not `motor_mode`), **`head_pose`** (RPY object, NOT a 16-element matrix), **`antennas_position`** (not `antennas`), and there is NO `is_move_running` — that signal comes from `/api/move/running` being non-empty.

```jsonc
{
  "control_mode": "enabled",
  "head_pose": { "x": ..., "y": ..., "z": ..., "roll": ..., "pitch": ..., "yaw": ... },
  "head_joints": null,
  "body_yaw": 0.0169,
  "antennas_position": [-0.1718, 0.1718],
  "timestamp": "2026-05-05T12:18:28.050628Z",
  "passive_joints": null,
  "doa": null
}
```

### `GET /api/daemon/status` — live response

```jsonc
{
  "type": "daemon_status",
  "robot_name": "reachy_mini",
  "state": "running",
  "wireless_version": true,
  "version": "1.7.1",
  "wlan_ip": "192.168.1.173",
  "no_media": false,
  "media_released": false,
  "camera_specs_name": "wireless",
  "backend_status": {
    "ready": false,
    "motor_control_mode": "enabled",
    "control_loop_stats": {
      "mean_control_loop_frequency": 49.6,
      "max_control_loop_interval": 0.02,
      "nb_error": 0,
      "motor_controller": "ControlLoopStats(period=~20.00ms, ...)"
    }
  }
}
```

### `GET /api/move/running`

`[]` when no move is in flight; populated when a recorded move is playing. **This is how we detect `is_move_running`** for `TargetStreamer`'s pause logic.

## Newly discovered endpoints

- `POST /api/media/play_sound` — body `{"file": "filename"}` plays a previously-uploaded sound. Path for **TTS playback through the robot speaker** (M5).
- `POST /api/media/sounds/upload` — upload PCM/WAV by filename.
- `GET /api/media/sounds` — list uploaded files.
- `DELETE /api/media/sounds/{filename}`
- `POST /api/media/stop_sound`
- `POST /api/media/acquire` / `release` — own/release media hardware (mirror of the SDK's `media_backend="no_media"`).
- `GET /api/media/status`
- `GET /api/move/recorded-move-datasets/list/{dataset_name}` — list recorded moves available in a dataset.
- `POST /api/move/play/recorded-move-dataset/{ds}/{move}` — play a recorded move (emotions library!).
- `GET /api/camera/specs` — resolutions + crop factors. `wireless` camera supports `1280x720@30fps`, `1920x1080@30fps`, `2304x1296@30fps`, `3072x1728@10fps` (truncated).
- `GET /api/kinematics/info`, `GET /api/kinematics/urdf`, `GET /api/kinematics/stl/{filename}` — for 3D head visualization in the dashboard.
- `GET /api/volume/current`, `POST /api/volume/set`, microphone variants.
- `POST /api/daemon/restart|start|stop` — daemon lifecycle from the app.
- HF auth + WiFi config endpoints — out of scope for Rocky.

## Smoke test (live, 2026-05-05)

```bash
curl -X POST http://reachy-mini.local:8000/api/move/set_target \
     -H "Content-Type: application/json" \
     -d '{"target_head_pose":{"x":0,"y":0,"z":0,"roll":0,"pitch":0,"yaw":0.0873}}'
# => {"status":"ok"} 200
```

State response confirmed the head started turning (yaw climbed from baseline ~0.012 toward our +0.087 target). Per memory rules, only a single small nudge was issued, then 0 to return.
