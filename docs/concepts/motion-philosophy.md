---
title: Motion philosophy
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/agents-md.md
  - https://github.com/pollen-robotics/reachy_mini/blob/main/skills/motion-philosophy.md
  - https://github.com/pollen-robotics/reachy_mini/blob/main/skills/control-loops.md
tags: [motion, control-loop]
---

# Motion philosophy

Two motion methods, two regimes. Choosing wrong = jerky motion or unresponsive apps.

## The two methods

| Method | Behavior | Use when |
|---|---|---|
| `goto_target(...)` | Smooth interpolation over a duration | Default. Gestures ≥0.5 s. Choreography. Transitions. |
| `set_target(...)` | Instant. No interpolation. | Real-time reactivity at ≥50 Hz. Tracking, games, joystick. |

## `goto_target`

Smooth interpolation in joint / cartesian space. The robot **commits** to the move — you cannot react mid-motion. That's a feature for emotions and choreography, a bug for tracking.

```python
from reachy_mini.utils import create_head_pose
import numpy as np

mini.goto_target(
    head=create_head_pose(yaw=30, pitch=10, degrees=True),
    antennas=np.deg2rad([45, 45]),
    body_yaw=np.deg2rad(30),
    duration=2.0,
    method="minjerk",   # linear | minjerk | ease_in_out | cartoon
)
```

Interpolation methods:

| Method | Character |
|---|---|
| `linear` | Constant speed. |
| `minjerk` | Natural and smooth. Default. |
| `ease_in_out` | Slow start and end. |
| `cartoon` | Exaggerated, bouncy. |

## `set_target`

Bypasses interpolation entirely. The robot tracks the target you sent. **You** are responsible for smoothing over time.

The single iron rule: **one control loop, one place calling `set_target()`.**

```python
while not stop_event.is_set():
    pose = compute_current_target_pose()    # function of state, not call site
    mini.set_target(head=pose)
    time.sleep(0.01)                        # ~100 Hz
```

Common mistake — scattered `set_target` calls:

```python
# DON'T
def on_face(face):     mini.set_target(head=look_at(face))
def on_button():       mini.set_target(head=neutral)
def idle():            mini.set_target(head=breathing)
```

```python
# DO — modify state, not call sites
def on_face(face):     ctrl.face_target = look_at(face)
def on_button():       ctrl.override = neutral
# control loop reads state, computes one pose, calls set_target once
```

## Frequency targets

| Hz | Use case |
|---|---|
| 100 | Real-time tracking, games. |
| 50 | Most interactive apps. |
| 30 | Minimum for "smooth enough". |
| <30 | Visibly jerky. |

Verify the daemon's control loop is running at ~50 Hz: `mini.client.get_status()` should report `period=~20ms`. See [run and debug](../workflows/run-and-debug.md).

## Pose fusion: primary + secondary

For complex apps (e.g., conversation app), separate **primary** moves (mutually exclusive: emotions, dances, breathing) from **secondary** offsets (face tracking, speech sync) that layer on top.

```
final_pose = primary_pose() ⊕ Σ secondary_offsets()
mini.set_target(head=final_pose)
```

Reference impl: `reachy_mini_conversation_app/src/reachy_mini_conversation_app/moves.py`. Open gap — full ingest pending.

## Project rules (memory)

- Face tracker should be **state-driven world-frame target + damped filter**, not per-frame P-control on raw image error.
- Robot safety: **small changes only** — never stack motion changes.
- **Don't band-aid**: after two failed tweaks in the same direction, stop and name the real problem.

## See also

- [Control loop pattern](../patterns/control-loop.md)
- [Coordinate frames](coordinate-frames.md)
- [Safety limits](safety-limits.md)
