---
title: Coordinate frames and units
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
tags: [frames, units, geometry]
---

# Coordinate frames and units

Two frames matter day-to-day:

| Frame | Origin | Used by |
|---|---|---|
| **Head frame** | Base of the head | `goto_target(head=...)`, `set_target(head=...)` — pose targets. |
| **World frame** | Fixed on the robot's base | `look_at_world(x, y, z)`, `look_at_image(px, py)`. |

For face tracking (per project memory), prefer **world-frame targets**: a 3D point that doesn't flicker as the camera image jitters frame-to-frame.

## Units

The SDK accepts both natural units (degrees / mm) and SI units (radians / meters). Always be explicit.

`create_head_pose(...)` keyword args:

```python
from reachy_mini.utils import create_head_pose

# Angles
create_head_pose(yaw=30, pitch=10, roll=5, degrees=True)        # degrees
create_head_pose(yaw=0.52, pitch=0.17, roll=0.087)              # radians (default)

# Translation
create_head_pose(x=0, y=0, z=10, mm=True)                       # millimeters
create_head_pose(x=0.0, y=0.0, z=0.01)                          # meters (default)
```

`antennas` and `body_yaw` are always **radians** when passed to `set_target` / `goto_target`. Convert with `np.deg2rad`.

## IMU units (Wireless only)

```python
imu = mini.imu
imu["accelerometer"]   # m/s²
imu["gyroscope"]       # rad/s
imu["quaternion"]      # (w, x, y, z)
imu["temperature"]     # °C
```

## Audio direction-of-arrival

`mini.media.get_DoA()` returns `(angle_radians, is_speech_detected)`:

- `0` rad → left
- `π/2` rad → front / back
- `π` rad → right

## See also

- [Safety limits](safety-limits.md) — what ranges are valid.
- [Motion philosophy](motion-philosophy.md)
- [Media architecture](media-architecture.md)
