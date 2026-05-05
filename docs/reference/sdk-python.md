---
title: Python SDK reference
type: reference
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # SDK/python-sdk, SDK/core-concept
  - https://github.com/pollen-robotics/reachy_mini/tree/main/examples
tags: [sdk, python, api]
---

# Python SDK reference (`reachy_mini`)

The class everything starts from is `ReachyMini`. Always use it as a context manager.

```python
from reachy_mini import ReachyMini

with ReachyMini() as mini:
    ...
```

## Constructor

```python
ReachyMini(
    connection_mode: str = "auto",       # "auto" | "localhost_only" | "network"
    media_backend: str = "default",      # "default" | "local" | "webrtc" | "no_media"
)
```

Auto-detection covers 95% of cases. Override only when needed.

## Motion

```python
from reachy_mini.utils import create_head_pose
import numpy as np

# Smooth interpolated motion — default for gestures
mini.goto_target(
    head=create_head_pose(z=10, mm=True),
    antennas=np.deg2rad([45, 45]),
    body_yaw=np.deg2rad(30),
    duration=2.0,
    method="minjerk",                   # linear | minjerk | ease_in_out | cartoon
)

# Instant target — for control loops only
mini.set_target(head=pose, antennas=[r_rad, l_rad], body_yaw=rad)

# Look helpers
mini.look_at_world(x, y, z)             # 3D point in world frame
mini.look_at_image(px, py, duration=0.3)  # 2D point in current camera image
```

`create_head_pose(...)` accepts `x`, `y`, `z`, `roll`, `pitch`, `yaw`, plus `degrees=False`, `mm=False`. See [coordinate frames](../concepts/coordinate-frames.md).

## Motor modes

```python
mini.enable_motors()                  # stiff
mini.disable_motors()                 # limp
mini.enable_gravity_compensation()    # soft (Placo only)
mini.make_motors_compliant()          # alias
```

## Sensors and media

### Camera

```python
frame = mini.media.get_frame()    # (H, W, 3) uint8
```

### Audio

```python
mini.media.start_recording()
mini.media.start_playing()

samples = mini.media.get_audio_sample()                # (N, 2) float32 @ 16 kHz
mini.media.push_audio_sample(samples)                  # non-blocking
doa, is_speech = mini.media.get_DoA()                  # rad, bool

mini.media.get_input_audio_samplerate()
mini.media.get_input_channels()
mini.media.get_output_audio_samplerate()
mini.media.get_output_channels()

mini.media.stop_recording()
mini.media.stop_playing()
```

### IMU (Wireless only)

```python
imu = mini.imu
imu["accelerometer"]   # m/s²
imu["gyroscope"]       # rad/s
imu["quaternion"]      # (w, x, y, z)
imu["temperature"]     # °C
```

### Direct hardware (release media manager)

```python
with ReachyMini(media_backend="no_media") as mini:
    import cv2; cap = cv2.VideoCapture(0); ...
    mini.goto_target(...)   # robot control still works

# or toggle at runtime
mini.release_media()
# ... use OpenCV / sounddevice ...
mini.acquire_media()
```

See [direct hardware pattern](../patterns/direct-hardware.md).

## Recording moves

```python
mini.start_recording()
# ... move robot manually with gravity_compensation, or via set_target ...
move = mini.stop_recording()
mini.play_move(move)
```

Pre-baked emotions:

```python
from reachy_mini.motion.recorded_move import RecordedMoves

moves = RecordedMoves("pollen-robotics/reachy-mini-emotions-library")
mini.play_move(moves.get("happy"), initial_goto_duration=1.0)
```

`initial_goto_duration` smooths the transition from the current pose to the move's first frame. Without it the robot jumps.

## State and diagnostics

```python
mini.state                        # joint positions, motor status, etc.
mini.client.get_status()          # daemon control-loop stats
```

A healthy control loop reports `period=~20ms` (50 Hz) and small read/write deltas. If the period is much higher, motion will look shaky — see [run and debug](../workflows/run-and-debug.md).

## App scaffolding

`ReachyMiniApp` is the base class for installed apps. See [app lifecycle](../concepts/app-lifecycle.md) and [create an app](../workflows/create-app.md).

## See also

- [Motion philosophy](../concepts/motion-philosophy.md)
- [Media architecture](../concepts/media-architecture.md)
- [Control loop pattern](../patterns/control-loop.md)
- [Direct hardware pattern](../patterns/direct-hardware.md)
