"""Synthetic detector for offline / smoke testing.

Generates a "face" that traces a slow Lissajous figure across the frame,
with optional lost-detection windows so we can verify the controller's
decay-toward-home behavior.

Configurable via env (`ROCKY_FT_SYN_*`) so the manifest can tune behavior
without code changes.
"""

from __future__ import annotations

import math
import os
import random
from dataclasses import dataclass
from time import monotonic
from typing import Optional

from .controller import Detection


@dataclass
class SyntheticConfig:
    frame_w: int = 1280
    frame_h: int = 720
    period_x_s: float = 8.0
    period_y_s: float = 5.0
    amplitude: float = 0.6   # fraction of half-frame
    bbox_size_norm: float = 0.18
    confidence: float = 0.85
    drop_probability: float = 0.05  # frame-level "lost detection"
    drop_window_s: float = 2.5      # bigger gap every N seconds
    drop_window_duration_s: float = 1.0


def from_env() -> SyntheticConfig:
    def _f(name: str, default: float) -> float:
        try:
            return float(os.environ[name])
        except (KeyError, ValueError):
            return default
    return SyntheticConfig(
        frame_w=int(_f("ROCKY_FT_SYN_W", 1280)),
        frame_h=int(_f("ROCKY_FT_SYN_H", 720)),
        period_x_s=_f("ROCKY_FT_SYN_PERIOD_X", 8.0),
        period_y_s=_f("ROCKY_FT_SYN_PERIOD_Y", 5.0),
        amplitude=_f("ROCKY_FT_SYN_AMPLITUDE", 0.6),
        bbox_size_norm=_f("ROCKY_FT_SYN_BBOX", 0.18),
        confidence=_f("ROCKY_FT_SYN_CONF", 0.85),
        drop_probability=_f("ROCKY_FT_SYN_DROP_P", 0.05),
        drop_window_s=_f("ROCKY_FT_SYN_DROP_EVERY", 2.5),
        drop_window_duration_s=_f("ROCKY_FT_SYN_DROP_DUR", 1.0),
    )


class SyntheticDetector:
    def __init__(self, cfg: SyntheticConfig | None = None,
                 prompt_id: str = "synthetic"):
        self.cfg = cfg or SyntheticConfig()
        self.prompt_id = prompt_id
        self._t0 = monotonic()
        self._rand = random.Random(42)

    def step(self) -> Optional[Detection]:
        now = monotonic()
        t = now - self._t0

        # Periodic "blackout" windows so we exercise decay-toward-home.
        phase = t % self.cfg.drop_window_s
        if phase < self.cfg.drop_window_duration_s:
            return None
        if self._rand.random() < self.cfg.drop_probability:
            return None

        cx_n = self.cfg.amplitude * math.sin(2 * math.pi * t / self.cfg.period_x_s)
        cy_n = (self.cfg.amplitude * 0.6) * math.sin(2 * math.pi * t / self.cfg.period_y_s)
        cx = (cx_n + 1.0) * 0.5 * self.cfg.frame_w
        cy = (cy_n + 1.0) * 0.5 * self.cfg.frame_h

        bw = self.cfg.bbox_size_norm * self.cfg.frame_w
        bh = self.cfg.bbox_size_norm * self.cfg.frame_h

        return Detection(
            bbox_xywh=(cx - bw / 2, cy - bh / 2, bw, bh),
            confidence=self.cfg.confidence,
            frame_w=self.cfg.frame_w,
            frame_h=self.cfg.frame_h,
            prompt_id=self.prompt_id,
            ts=now,
        )
