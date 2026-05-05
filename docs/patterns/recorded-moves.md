---
title: Record and replay motion
type: pattern
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # SDK/python-sdk + troubleshooting
  - sources/agents-md.md
tags: [recording, emotions, dances]
---

# Pattern — record and replay motion

Two ways to get a motion: capture it live (teach-by-demo), or load one from a Hugging Face dataset.

## Capture a move (live)

```python
with ReachyMini() as mini:
    mini.enable_gravity_compensation()    # let it be moved by hand
    mini.start_recording()
    input("Move the robot, then press Enter…")
    move = mini.stop_recording()

mini.play_move(move)                       # replay
```

You can also capture the output of `set_target` in a control loop the same way — useful for capturing programmed sequences for later reuse.

## Pre-baked emotions library

```python
from reachy_mini.motion.recorded_move import RecordedMoves

moves = RecordedMoves("pollen-robotics/reachy-mini-emotions-library")
mini.play_move(moves.get("happy"), initial_goto_duration=1.0)
```

`initial_goto_duration` smooths the transition from the current pose to the move's first frame. Without it the robot jumps.

## Dances

Same mechanism, different dataset: `pollen-robotics/reachy_mini_dances_library` (open gap — not ingested in detail).

## Listing available moves

```python
print(list(moves.keys()))
```

(Confirm signature against current SDK — open gap.)

## Composing recorded moves with a live control loop

Recorded moves are **primary** in pose-fusion terms — they take over the head while playing. If you have a control loop running, ensure it pauses (or yields to the recorded move) for the duration of `play_move`. The conversation app shows one way to coordinate this; see the open gap on `moves.py`.

## Saving and reusing your own moves

`RecordedMoves` reads from HF datasets. You can publish your own captures as a private dataset and load them by URL. Workflow not documented in detail in our wiki yet — open gap.

## See also

- [Motion philosophy](../concepts/motion-philosophy.md)
- [App lifecycle](../concepts/app-lifecycle.md)
- [Python SDK reference](../reference/sdk-python.md)
