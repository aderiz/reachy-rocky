"""Robot camera sidecar.

Connects to the Reachy Mini daemon via the `reachy_mini` SDK, polls
`mini.media.get_frame()`, downsamples to ~480 px wide, JPEG-encodes,
and emits `frame` events to Rocky over the Sidecar wire.
"""

from .runner import main

__all__ = ["main"]
