"""Robot camera sidecar.

Connects to the Reachy Mini daemon via the `reachy_mini` SDK, polls
`mini.media.get_frame()`, downsamples to ~480 px wide, JPEG-encodes,
and emits `frame` events to Rocky over the Sidecar wire.
"""

# Intentionally empty — see `rocky_robot_mic/__init__.py` for the
# rationale. Importing `runner` from `__init__.py` causes a double-
# import when launched via `python -m rocky_robot_camera.runner`.

__all__: list[str] = []
