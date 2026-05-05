"""State-driven face-tracker controller.

This is the core algorithm, decoupled from any specific detector or
runtime. The detector thread reports `Detection`s (or none) at whatever
rate it can manage; the controller's `tick(dt)` advances the commanded
head pose toward the smoothed world-frame target.

Critical design rule (memory: project_face_tracker_design.md):
  Detection rate and motion smoothness are decoupled. Don't regress to
  per-frame P-control on raw image error — that produces burst-and-stall
  motion that no amount of tuning fixes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from time import monotonic
from typing import Optional

from .filters import EMA, CriticalDamper
from .geometry import CameraIntrinsics, angle_from_pixel, normalized_bbox_center


@dataclass(frozen=True)
class Detection:
    """A single face/person detection, with timestamp."""
    bbox_xywh: tuple[float, float, float, float]
    confidence: float
    frame_w: int
    frame_h: int
    prompt_id: str
    ts: float            # monotonic seconds


@dataclass
class FaceTrackerConfig:
    intrinsics: CameraIntrinsics = field(default_factory=CameraIntrinsics)
    ema_alpha: float = 0.5
    damper_omega: float = 3.0
    idle_timeout_s: float = 1.5
    decay_per_second: float = 0.6     # how fast world target eases home
    min_confidence: float = 0.3
    min_bbox_norm: float = 0.05       # ignore bboxes smaller than 5% of frame


class FaceTrackerController:
    """Owns the world-frame target and the commanded-pose dampers."""

    def __init__(self, cfg: FaceTrackerConfig | None = None) -> None:
        self.cfg = cfg or FaceTrackerConfig()
        self._world_yaw_ema = EMA(self.cfg.ema_alpha)
        self._world_pitch_ema = EMA(self.cfg.ema_alpha)
        self._yaw_damp = CriticalDamper(self.cfg.damper_omega)
        self._pitch_damp = CriticalDamper(self.cfg.damper_omega)
        self._last_detection_ts: Optional[float] = None

        # Commanded head yaw/pitch fed back from the daemon (or last sent).
        self._cmd_head_yaw = 0.0
        self._cmd_head_pitch = 0.0

    # --- detector callbacks ---

    def ingest_detection(self, det: Detection) -> bool:
        """Convert detection into a fresh world-frame target, EMA-smooth it.

        Returns True if the detection was accepted (passed gating).
        """
        if det.confidence < self.cfg.min_confidence:
            return False
        _x, _y, w, h = det.bbox_xywh
        bbox_norm = max(w / det.frame_w, h / det.frame_h)
        if bbox_norm < self.cfg.min_bbox_norm:
            return False

        un, vn = normalized_bbox_center(det.bbox_xywh, det.frame_w, det.frame_h)
        yaw_off, pitch_off = angle_from_pixel(un, vn, self.cfg.intrinsics)

        target_yaw = self._cmd_head_yaw + yaw_off
        target_pitch = self._cmd_head_pitch + pitch_off

        self._world_yaw_ema.update(target_yaw)
        self._world_pitch_ema.update(target_pitch)
        self._last_detection_ts = det.ts
        return True

    # --- daemon state callback ---

    def update_commanded_pose(self, yaw_rad: float, pitch_rad: float) -> None:
        self._cmd_head_yaw = yaw_rad
        self._cmd_head_pitch = pitch_rad

    # --- 50 Hz tick ---

    def tick(self, dt: float, now: float | None = None
             ) -> tuple[float, float, bool]:
        """Advance dampers; return (yaw_cmd, pitch_cmd, decay_active)."""
        now = now if now is not None else monotonic()
        decay_active = self._maybe_decay_target(now, dt)

        target_yaw = self._world_yaw_ema.value if self._world_yaw_ema.initialized else 0.0
        target_pitch = self._world_pitch_ema.value if self._world_pitch_ema.initialized else 0.0

        yaw_cmd = self._yaw_damp.step(dt, target_yaw)
        pitch_cmd = self._pitch_damp.step(dt, target_pitch)
        return yaw_cmd, pitch_cmd, decay_active

    # --- internal ---

    def _maybe_decay_target(self, now: float, dt: float) -> bool:
        """If we haven't seen a detection in idle_timeout_s, ease the world
        target toward (0, 0) at `decay_per_second` rate."""
        if self._last_detection_ts is None:
            # Never had a detection: target is already 0, nothing to do.
            return False
        elapsed = now - self._last_detection_ts
        if elapsed < self.cfg.idle_timeout_s:
            return False
        # Exponential decay toward zero.
        factor = max(0.0, 1.0 - self.cfg.decay_per_second * dt)
        self._world_yaw_ema.value *= factor
        self._world_pitch_ema.value *= factor
        return True
