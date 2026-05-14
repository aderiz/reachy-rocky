"""On-bot motion guard.

Mirrors the Swift `MotionGuard` (`Sources/RobotLink/MotionGuard.swift`)
on the bot, in front of the Pollen daemon. Every motion call from
Mac (or any other client) arrives at :8042/api/motion/* on this
relay; we validate against the safety constraints, then forward to
the daemon's localhost:8000/api/move/*.

This is the bot-side half of defence-in-depth motion safety. The
Mac-side `MotionGuard` catches *our* bugs early (fast failure, fast
feedback during development). This bot-side guard catches everything
else — a future SDK app on the bot, a debug curl from another
machine, a malicious request — none of them can reach the daemon
without passing through here.

Pollen's docs say the daemon clamps positions to valid ranges, but
the daemon does NOT enforce velocity, slew-rate, single-in-flight,
or any "shelf-safe" recorded-move allowlist. So those guards have to
live somewhere; this is the canonical home.

Guards enforced (same five as the Swift side):
  1. Slew-rate limit on set_target (0.05 rad / call ≈ 143°/s @ 50 Hz)
  2. Velocity clamp on goto (head + body + antennas, 1.5 rad/s default)
  3. Duration floor on goto (0.4 s)
  4. Single-in-flight goto (new awaits prior)
  5. Shelf-safe allowlist for recorded moves (force=true to override)
  6. Head-body yaw delta cap (Pollen-documented 65°)
"""

from __future__ import annotations

import asyncio
import logging
import math
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx

LOG = logging.getLogger("rocky_media_relay.motion_guard")

DAEMON_BASE = "http://127.0.0.1:8000"


@dataclass
class GuardConfig:
    """Tunable thresholds. Defaults match the Swift MotionGuard.Config."""

    max_set_target_slew_rad: float = 0.05         # ~143°/s at 50 Hz
    min_goto_duration_s: float = 0.4              # snap-floor
    max_goto_velocity_rad_per_s: float = 1.5      # ~86°/s
    max_head_body_yaw_delta_rad: float = 65.0 * math.pi / 180.0
    shelf_safe_moves: frozenset[str] = field(
        default_factory=lambda: frozenset({
            "amazed1", "attentive1", "calming1", "cheerful1",
            "curious1", "grateful1", "helpful1", "indifferent1",
            "inquiring1", "no1", "no_sad1", "proud1", "relief1",
            "sad1", "serenity1", "shy1", "thoughtful1", "tired1",
            "understanding1", "welcoming1", "yes1", "yes_sad1",
            "downcast1", "lonely1", "loving1", "uncertain1",
            # The wake / sleep recorded moves are intentionally
            # included — they're designed for the desk shelf.
            "wake_up", "goto_sleep",
        })
    )


class MotionGuard:
    def __init__(self, config: Optional[GuardConfig] = None) -> None:
        self.config = config or GuardConfig()
        self._http = httpx.AsyncClient(
            base_url=DAEMON_BASE, timeout=httpx.Timeout(10.0, connect=2.0)
        )
        # Slew limiter state.
        self._last_target: Optional[dict[str, Any]] = None
        # Single-in-flight goto serialisation.
        self._goto_lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._http.aclose()

    # ------------------------------------------------------------------
    # setTarget (slew-rate limited)
    # ------------------------------------------------------------------

    async def set_target(self, target: dict[str, Any]) -> httpx.Response:
        limited = self._slew_limit(target)
        self._last_target = limited
        return await self._http.post("/api/move/set_target", json=limited)

    def _slew_limit(self, target: dict[str, Any]) -> dict[str, Any]:
        prev = self._last_target
        if not prev:
            return target
        max_slew = self.config.max_set_target_slew_rad
        out = dict(target)

        new_head = target.get("target_head_pose")
        prev_head = prev.get("target_head_pose")
        if new_head is not None and prev_head is not None:
            out["target_head_pose"] = {
                "roll": _clamp_delta(new_head.get("roll", 0), prev_head.get("roll", 0), max_slew),
                "pitch": _clamp_delta(new_head.get("pitch", 0), prev_head.get("pitch", 0), max_slew),
                "yaw": _clamp_delta(new_head.get("yaw", 0), prev_head.get("yaw", 0), max_slew),
            }

        new_ant = target.get("target_antennas")
        prev_ant = prev.get("target_antennas")
        if new_ant is not None and prev_ant is not None and len(new_ant) == 2 and len(prev_ant) == 2:
            out["target_antennas"] = [
                _clamp_delta(new_ant[0], prev_ant[0], max_slew),
                _clamp_delta(new_ant[1], prev_ant[1], max_slew),
            ]

        new_body = target.get("target_body_yaw")
        prev_body = prev.get("target_body_yaw")
        if new_body is not None and prev_body is not None:
            out["target_body_yaw"] = _clamp_delta(new_body, prev_body, max_slew)

        return out

    # ------------------------------------------------------------------
    # goto (velocity clamp + duration floor + single-in-flight +
    #       head/body yaw delta gate)
    # ------------------------------------------------------------------

    async def goto(self, body: dict[str, Any]) -> httpx.Response:
        async with self._goto_lock:
            # Head-body yaw delta gate (Pollen-documented constraint).
            body = await self._reshape_for_yaw_delta(body)

            # Duration floor + velocity clamp.
            requested = max(
                float(body.get("duration", 0.7)),
                self.config.min_goto_duration_s,
            )
            safe = await self._safe_duration(body, requested)
            if safe > requested:
                LOG.warning(
                    "goto duration stretched %.2fs → %.2fs (velocity cap)",
                    requested, safe,
                )
            body = {**body, "duration": safe}
            return await self._http.post("/api/move/goto", json=body)

    async def _safe_duration(self, body: dict[str, Any], requested: float) -> float:
        try:
            cur = await self._get_current_state()
        except Exception as exc:  # noqa: BLE001
            LOG.warning("state read failed (%s); using requested duration", exc)
            return requested

        max_delta = 0.0
        head = body.get("head_pose")
        if head is not None and cur is not None:
            cur_head = cur.get("head_pose", {})
            for k in ("roll", "pitch", "yaw"):
                if k in head and k in cur_head:
                    max_delta = max(max_delta, abs(head[k] - cur_head[k]))
        body_yaw = body.get("body_yaw")
        if body_yaw is not None and cur is not None and cur.get("body_yaw") is not None:
            max_delta = max(max_delta, abs(body_yaw - cur["body_yaw"]))
        antennas = body.get("antennas")
        if antennas is not None and cur is not None:
            cur_ant = cur.get("antennas_position", [0.0, 0.0])
            if len(antennas) == 2 and len(cur_ant) == 2:
                max_delta = max(max_delta, abs(antennas[0] - cur_ant[0]))
                max_delta = max(max_delta, abs(antennas[1] - cur_ant[1]))
        min_safe = max_delta / self.config.max_goto_velocity_rad_per_s
        return max(requested, min_safe)

    async def _reshape_for_yaw_delta(self, body: dict[str, Any]) -> dict[str, Any]:
        head = body.get("head_pose")
        body_yaw = body.get("body_yaw")
        try:
            cur = await self._get_current_state()
        except Exception:  # noqa: BLE001
            cur = None
        cur_head_yaw = (cur or {}).get("head_pose", {}).get("yaw", 0.0) if cur else 0.0
        cur_body_yaw = (cur or {}).get("body_yaw", 0.0) if cur else 0.0
        target_head_yaw = head.get("yaw", cur_head_yaw) if head is not None else cur_head_yaw
        target_body_yaw = body_yaw if body_yaw is not None else cur_body_yaw
        delta = target_head_yaw - target_body_yaw
        max_delta = self.config.max_head_body_yaw_delta_rad
        if abs(delta) <= max_delta:
            return body
        excess = abs(delta) - max_delta
        direction = 1.0 if delta > 0 else -1.0
        new_head_yaw = target_head_yaw
        new_body_yaw = target_body_yaw
        if head is not None and body_yaw is not None:
            new_head_yaw -= direction * excess / 2
            new_body_yaw += direction * excess / 2
        elif head is not None:
            new_head_yaw -= direction * excess
        elif body_yaw is not None:
            new_body_yaw += direction * excess
        LOG.warning(
            "yaw-delta limit: head %.1f° + body %.1f° (Δ %.1f°) → head %.1f° + body %.1f° (Δ %.1f°)",
            math.degrees(target_head_yaw), math.degrees(target_body_yaw),
            math.degrees(delta),
            math.degrees(new_head_yaw), math.degrees(new_body_yaw),
            math.degrees(new_head_yaw - new_body_yaw),
        )
        out = dict(body)
        if head is not None:
            out["head_pose"] = {**head, "yaw": new_head_yaw}
        if body_yaw is not None:
            out["body_yaw"] = new_body_yaw
        return out

    # ------------------------------------------------------------------
    # Recorded moves (shelf-safe allowlist)
    # ------------------------------------------------------------------

    async def play_recorded_move(
        self, dataset: str, move: str, force: bool = False
    ) -> httpx.Response:
        if not force and move not in self.config.shelf_safe_moves:
            LOG.warning(
                "blocked recorded move '%s' (dataset=%s) — not in shelf-safe allowlist",
                move, dataset,
            )
            return _denied_response(
                f"recorded move '{move}' is not on the shelf-safe allowlist; "
                "use force=true to override (CHECK SHELF FIRST)"
            )
        # Daemon endpoint shape:
        #   /api/move/play/recorded-move-dataset/{dataset}/{move}   — emotion library
        #   /api/move/play/{move}                                   — built-in (wake_up, goto_sleep)
        # The dataset is None / empty for the built-ins; the relay
        # routes accordingly.
        if dataset:
            path = f"/api/move/play/recorded-move-dataset/{dataset}/{move}"
        else:
            path = f"/api/move/play/{move}"
        return await self._http.post(path)

    # ------------------------------------------------------------------
    # Pass-throughs (non-velocity-sensitive)
    # ------------------------------------------------------------------

    async def reset_slew_baseline(self, target: dict[str, Any]) -> None:
        """Drop the slew limiter's cached prev so the *next* setTarget
        is treated as the new ground-truth. Used by the wake-up
        sequence: the pre-seed setTarget MUST land exactly at the
        current physical pose (the whole point is to avoid a motor
        snap when motors enable). Without this, slew clamping
        anchors the daemon at (previous_face_tracker_target +
        max_slew) — the motors then engage to that clamped value,
        not the physical pose, which reads as an aggressive wake.
        """
        self._last_target = target

    async def wake_up(self, goto_duration_s: float = 3.5) -> dict[str, Any]:
        """Orchestrate the wake-up sequence on the bot itself, so the
        on-bot guard owns the slew baseline reset.

        Steps (matches the Swift-side composite the daemon doesn't
        provide on its own):
          1. Read current physical pose (state/full).
          2. Reset slew baseline to that pose.
          3. setTarget(currentPose) — pre-seed; with the baseline
             reset, this passes through unclamped, so the daemon's
             commanded target now matches physical.
          4. setMotorMode(enabled) — motors engage from physical →
             physical → no snap.
          5. goto(neutral, durationS=goto_duration_s, minjerk) — the
             slow swing up to looking-forward. 3.5 s by default
             (was 2 s in the Swift composite — too fast).
        """
        # 1. Read current pose.
        try:
            r = await self._http.get(
                "/api/state/full",
                params={
                    "with_head_joints": "true",
                    "with_body_yaw": "true",
                    "with_antenna_positions": "true",
                },
            )
            cur = r.json() if r.status_code == 200 else {}
        except Exception:  # noqa: BLE001
            cur = {}
        head_pose = cur.get("head_pose") or {"roll": 0.0, "pitch": 0.0, "yaw": 0.0}
        body_yaw = cur.get("body_yaw") if cur.get("body_yaw") is not None else 0.0
        ant = cur.get("antennas_position") or [0.1745, -0.1745]

        anchor_target = {
            "target_head_pose": head_pose,
            "target_body_yaw": body_yaw,
            "target_antennas": list(ant),
        }

        # 2-3. Reset baseline + pre-seed.
        await self.reset_slew_baseline(anchor_target)
        try:
            await self._http.post("/api/move/set_target", json=anchor_target)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("wake_up: pre-seed setTarget failed: %s", exc)
        await asyncio.sleep(0.05)

        # 4. Engage motors. Daemon endpoint is plural / URL-based.
        try:
            await self._http.post("/api/motors/set_mode/enabled")
        except Exception as exc:  # noqa: BLE001
            LOG.warning("wake_up: setMotorMode failed: %s", exc)
        await asyncio.sleep(0.15)

        # 5. Smooth swing to neutral. Duration is configurable so
        # the user can dial it gentler if needed.
        neutral = {"roll": 0.0, "pitch": 0.0, "yaw": 0.0}
        try:
            await self._http.post(
                "/api/move/goto",
                json={
                    "head_pose": neutral,
                    "antennas": None,
                    "body_yaw": None,
                    "duration": max(goto_duration_s, 1.0),
                    "interpolation": "minjerk",
                },
            )
        except Exception as exc:  # noqa: BLE001
            LOG.warning("wake_up: goto neutral failed: %s", exc)

        # 6. Re-assert motor enable (the Swift composite did this).
        try:
            await self._http.post("/api/motors/set_mode/enabled")
        except Exception:  # noqa: BLE001
            pass

        # Slew baseline now sits at the neutral pose (subsequent
        # tracker pushes clamp from here).
        self._last_target = {
            "target_head_pose": neutral,
            "target_body_yaw": 0.0,
            "target_antennas": list(ant),
        }
        return {"ok": True, "guard": "on-bot", "goto_duration_s": max(goto_duration_s, 1.0)}

    async def set_motor_mode(self, mode: str) -> httpx.Response:
        # Daemon endpoint shape (confirmed via :8000/openapi.json):
        #   POST /api/motors/set_mode/{mode}     ← plural "motors",
        #   no body. Earlier versions of this guard used
        #   `/api/motor/mode` with a JSON body, which 404'd silently
        #   — that's why the wake-up sequence's motor-enable step
        #   was failing and the bot wasn't actually waking.
        return await self._http.post(f"/api/motors/set_mode/{mode}")

    async def stop_move(self) -> httpx.Response:
        return await self._http.post("/api/move/stop_move")

    async def daemon_proxy(self, method: str, path: str, **kwargs) -> httpx.Response:
        """Generic passthrough for state reads / other non-motion daemon calls."""
        return await self._http.request(method, path, **kwargs)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    async def _get_current_state(self) -> Optional[dict[str, Any]]:
        try:
            r = await self._http.get(
                "/api/state/full",
                params={
                    "with_head_joints": "true",
                    "with_body_yaw": "true",
                    "with_antenna_positions": "true",
                },
            )
            if r.status_code == 200:
                return r.json()
        except Exception as exc:  # noqa: BLE001
            LOG.debug("state read failed: %s", exc)
        return None


def _clamp_delta(new: float, prev: float, max_delta: float) -> float:
    delta = new - prev
    if abs(delta) <= max_delta:
        return new
    return prev + (max_delta if delta > 0 else -max_delta)


class _DummyResponse:
    """Stand-in for httpx.Response when the guard rejects a request."""

    def __init__(self, status_code: int, payload: dict[str, Any]) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> dict[str, Any]:
        return self._payload

    @property
    def text(self) -> str:
        import json as _json
        return _json.dumps(self._payload)


def _denied_response(reason: str) -> Any:
    return _DummyResponse(
        status_code=403,
        payload={"ok": False, "error": reason, "guard": "motion-guard"},
    )
