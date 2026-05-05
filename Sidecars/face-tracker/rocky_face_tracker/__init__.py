"""Rocky face-tracker sidecar.

State-driven SAM 3.1 face tracker re-implemented under the Sidecar contract.

Architecture (per docs/concepts/motion-philosophy.md and the project's
face-tracker design memory):

  * Detector thread:
      pixel offset of detected face/body bbox  -> camera-frame angle
      add current commanded head yaw/pitch     -> world-frame target
      EMA-smooth (alpha ~ 0.5) the world target
  * Command thread (50 Hz):
      A pair of CriticalDamper instances (omega = 3 rad/s) advance the
      *commanded* head yaw/pitch toward the world target.
      Emits {"event":"target", ...} on every tick.
  * On detection-loss (> idle_timeout) the world target slowly decays
      toward (0, 0). The damper smoothly tracks the decay, so the head
      drifts home rather than snapping.

Two detector backends share the controller:
  * synthetic  -> tests / offline iteration; no MLX or robot needed.
  * sam        -> real SAM 3.1 (mlx-community/sam3.1-bf16) + Reachy SDK
                  camera frames. Enabled when the `sam` extras install.
"""

from .geometry import angle_from_pixel, normalized_bbox_center
from .filters import EMA, CriticalDamper
from .controller import FaceTrackerController, FaceTrackerConfig

__all__ = [
    "EMA",
    "CriticalDamper",
    "FaceTrackerController",
    "FaceTrackerConfig",
    "angle_from_pixel",
    "normalized_bbox_center",
]
