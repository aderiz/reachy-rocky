---
title: Safety limits
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
  - sources/agents-md.md
tags: [safety, limits]
---

# Safety limits

The SDK clamps any out-of-range pose to the nearest valid one — but you should still respect the limits to keep behavior predictable.

| Joint / axis | Range |
|---|---|
| Head pitch | ±40° |
| Head roll | ±40° |
| Head yaw | ±180° |
| Body yaw | ±160° |
| `head_yaw - body_yaw` (yaw delta) | ≤65° |

The yaw-delta constraint is the easiest to violate accidentally — turning the head far while the body is also turned the other way can exceed 65° even if both are individually inside their ranges.

Gentle collisions with the body during some bundled emotions are expected — the contact is intentional in those moves and not a bug.

## Motor modes

```python
mini.enable_motors()                  # stiff — holds position
mini.disable_motors()                 # limp — no power, robot collapses to rest
mini.enable_gravity_compensation()    # "soft" — push by hand, holds where you leave it
mini.make_motors_compliant()          # alias for the above
```

`gravity_compensation` requires the Placo kinematics backend. Use it for teach-by-demonstration recording.

## Wake / sleep

A robot in sleep pose has motors **disabled**. `set_target` is silently ignored when motors are disabled — apps look broken. The fix: ensure motors are enabled before sending pose targets.

In Python: `mini.enable_motors()` after construction (or rely on `wrapped_run()` in apps).
In JS: `await robot.ensureAwake()` after `startSession()`.

## Project rules (memory)

- **Small changes only** — never stack motion-control changes. One tweak, verify calm, then next.
- **Don't band-aid** — after two failed tweaks in the same direction, stop and name the real problem; revert if needed.

## See also

- [Motion philosophy](motion-philosophy.md)
- [Coordinate frames](coordinate-frames.md)
- [Motors reference](../reference/motors.md)
