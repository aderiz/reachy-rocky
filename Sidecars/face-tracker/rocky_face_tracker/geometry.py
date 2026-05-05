"""Pixel <-> camera-frame angle conversions.

Reachy Mini's wide-angle camera streams 1280 x 720 frames at HFOV ~65 deg,
VFOV ~39 deg (per the project face-tracker design memory). For this
sidecar we accept any frame size and normalize to [-1, +1].

Sign conventions (must match the Reachy Mini head frame):
  * +yaw   = head LEFT  (so a face on the *left* of the image -> +yaw)
  * +pitch = head DOWN  (so a face on the *bottom* -> +pitch)

`un` is the normalized horizontal offset where -1 = left edge, +1 = right.
`vn` is the normalized vertical offset where -1 = top, +1 = bottom.
"""

from __future__ import annotations

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class CameraIntrinsics:
    hfov_deg: float = 65.0
    vfov_deg: float = 39.0

    @property
    def hfov_rad(self) -> float:
        return math.radians(self.hfov_deg)

    @property
    def vfov_rad(self) -> float:
        return math.radians(self.vfov_deg)


def normalized_bbox_center(bbox: tuple[float, float, float, float],
                            frame_w: int,
                            frame_h: int) -> tuple[float, float]:
    """Return (un, vn) in [-1, +1] from an (x, y, w, h) bbox in pixels."""
    x, y, w, h = bbox
    cx = x + 0.5 * w
    cy = y + 0.5 * h
    un = (cx / frame_w) * 2.0 - 1.0
    vn = (cy / frame_h) * 2.0 - 1.0
    return un, vn


def angle_from_pixel(un: float, vn: float, intrinsics: CameraIntrinsics
                     ) -> tuple[float, float]:
    """Camera-frame yaw/pitch offsets in radians.

    target_yaw_offset   = -un * HFOV / 2     (face on left -> head turns LEFT)
    target_pitch_offset = +vn * VFOV / 2     (face below   -> head pitches DOWN)
    """
    yaw_offset = -un * (intrinsics.hfov_rad / 2.0)
    pitch_offset = vn * (intrinsics.vfov_rad / 2.0)
    return yaw_offset, pitch_offset
