---
title: Direct hardware access (bypass media manager)
type: pattern
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # SDK/media-architecture
tags: [media, opencv, sounddevice, no_media]
---

# Pattern — direct hardware access

When you need OpenCV, sounddevice, or any other library to own the camera or audio device directly, ask the daemon to release them.

## Construct with `no_media`

```python
from reachy_mini import ReachyMini
import cv2

with ReachyMini(media_backend="no_media") as mini:
    cap = cv2.VideoCapture(0)              # daemon released the camera
    ret, frame = cap.read()
    cap.release()

    mini.goto_target(antennas=[0.3, -0.3], duration=0.5)   # robot control still works

# on exit, the daemon re-acquires the hardware automatically
```

## Toggle at runtime

```python
mini = ReachyMini()           # daemon owns hardware via SDK media manager
frame = mini.media.get_frame()

mini.release_media()
# ... use OpenCV / sounddevice / Whisper / whatever ...

mini.acquire_media()          # back to SDK media
frame = mini.media.get_frame()
```

`release_media` and `acquire_media` are idempotent — calling either twice is safe.

## Why use this

- Custom OpenCV pipelines (face detection, calibrated camera ops, ArUco markers).
- Whisper / sounddevice for STT outside the SDK's audio loop.
- Profiling: avoiding the GStreamer pipeline cost.
- Anything that needs a `cv2.VideoCapture(0)` device handle.

## Pitfalls

- Linux: `OSError: PortAudio library not found` when using `sounddevice` → `sudo apt-get install libportaudio2`.
- Don't forget the SDK's audio is 16 kHz stereo float32 — if you bypass it, manage your own format.
- Don't try to share devices with the SDK's media manager simultaneously. Use `release_media()` first.
- On the Wireless, `cv2.VideoCapture(0)` opens libcamera/v4l2 the same way the daemon does — the daemon must have released first.

## Worked example: click-to-look (uses default media manager — counterexample)

The bundled `examples/look_at_image.py` does **not** use `no_media`. It opens a window with `cv2.imshow`, fetches frames via the SDK's `mini.media.get_frame()`, and calls `mini.look_at_image(x, y)` on click. That's the right approach when you only need *display*, not direct device access:

```python
with ReachyMini(media_backend=backend) as reachy_mini:
    while True:
        frame = reachy_mini.media.get_frame()
        cv2.imshow("Reachy Mini Camera", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break
        if state["just_clicked"]:
            reachy_mini.look_at_image(state["x"], state["y"], duration=0.3)
            state["just_clicked"] = False
```

If you needed `cv2.VideoCapture(0)` — say, to use OpenCV's exposure controls — you'd switch to `media_backend="no_media"`.

## See also

- [Media architecture](../concepts/media-architecture.md)
- [`look_at_image.py`](https://github.com/pollen-robotics/reachy_mini/blob/main/examples/look_at_image.py)
- [Python SDK reference](../reference/sdk-python.md)
