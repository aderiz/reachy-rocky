---
title: Single-loop control pattern
type: pattern
status: current
last_updated: 2026-05-05
sources:
  - https://github.com/pollen-robotics/reachy_mini/blob/main/skills/control-loops.md
  - sources/agents-md.md
tags: [control-loop, set_target, real-time]
---

# Pattern — single-loop control

Use this when the robot must react to inputs in real time (face tracking, joystick, games).

## The rule

> One control loop. One place calling `set_target()`. ~100 Hz.

External events update **state**, not the robot directly. The loop reads state, computes the final pose, sends one `set_target`. Sleep 10 ms. Repeat.

## Template

```python
import threading, time
import numpy as np
from reachy_mini import ReachyMini
from reachy_mini.utils import create_head_pose

class Controller:
    def __init__(self):
        self.stop_event = threading.Event()
        self.target_yaw_deg = 0.0
        self.target_pitch_deg = 0.0
        self.face_target_world = None    # e.g. (x, y, z) when a face is detected

    def control_loop(self, mini: ReachyMini):
        t0 = time.monotonic()
        while not self.stop_event.is_set():
            t = time.monotonic() - t0

            # Idle "breathing" — small pitch oscillation
            breathing = 2.0 * np.sin(2 * np.pi * 0.2 * t)

            pose = create_head_pose(
                yaw=self.target_yaw_deg,
                pitch=self.target_pitch_deg + breathing,
                degrees=True,
            )

            mini.set_target(head=pose)
            time.sleep(0.01)   # ~100 Hz

    def update_target(self, yaw_deg: float, pitch_deg: float):
        # Called from any thread / callback. Just mutate state.
        self.target_yaw_deg = yaw_deg
        self.target_pitch_deg = pitch_deg


controller = Controller()
with ReachyMini() as mini:
    t = threading.Thread(target=controller.control_loop, args=(mini,), daemon=True)
    t.start()
    try:
        # main thread does perception / IO / whatever
        ...
    finally:
        controller.stop_event.set()
        t.join()
```

## Why `time.monotonic()`

`time.time()` can jump (NTP sync, sleep/wake). `time.monotonic()` is robust to wall-clock changes. Always use it for control-loop phase.

## Mixing primary and secondary motion

For richer apps (conversation, choreography + tracking), keep the loop simple and let it consume **two state buckets**:

- `primary_pose()` — the dominant motion (emotion, dance, scripted gesture). Mutually exclusive.
- `secondary_offsets()` — additive deltas (face-tracking nudge, breathing, speech-sync mouth).

```
final = primary_pose(t) ⊕ Σ secondary_offsets(t)
mini.set_target(head=final)
```

Reference impl: `reachy_mini_conversation_app/src/reachy_mini_conversation_app/moves.py`. Open gap — full ingest pending; see [index](../index.md#open-gaps).

## Threading

- One dedicated worker thread owns robot output. Other threads communicate via mutexes / queues / atomic state.
- Never call `set_target()` from multiple threads — that's the same problem as scattered call sites.

## Memory: face tracker design

The face tracker for this project is **state-driven**:

- Maintain a target in world frame, not image frame.
- Smooth it with a damped filter (e.g., low-pass / critically-damped second-order filter).
- Feed the smoothed pose into the loop above as part of `secondary_offsets()` or as the dominant target when no primary move is active.
- **Do not regress** to per-frame P-control on raw image error — that approach was tried and rejected.

## See also

- [Motion philosophy](../concepts/motion-philosophy.md)
- [Coordinate frames](../concepts/coordinate-frames.md)
- [Direct hardware pattern](direct-hardware.md)
