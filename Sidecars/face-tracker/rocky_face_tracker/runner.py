"""Sidecar entry point.

Wires the controller, detector, and JSON-line wire format together:

    detector thread  ----+
                          \\
                           v
                   FaceTrackerController  -- 50 Hz tick -->  emit("target", ...)
                                                         \\
                                                          --> emit("detection", ...)

Methods callable from Swift:
    set_enabled(enabled: bool)
    set_prompt(text: str)             # informational; SAM detector picks up next start
    update_commanded_pose(yaw_rad, pitch_rad)
    health()
    shutdown()

Events emitted:
    {"event": "ready"}
    {"event": "target", "payload": {yaw_rad, pitch_rad, decay_active}}
    {"event": "detection", "payload": {bbox, confidence, prompt_id, frame_w, frame_h}}
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from typing import Any

from .controller import FaceTrackerConfig, FaceTrackerController
from .detector_synthetic import SyntheticDetector, from_env as syn_from_env
from .geometry import CameraIntrinsics


# --- IO helpers ---------------------------------------------------------

_io_lock = threading.Lock()


def emit(obj: dict[str, Any]) -> None:
    line = json.dumps(obj)
    with _io_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(level: str, msg: str, **fields: Any) -> None:
    emit({"log": {"level": level, "msg": msg, "fields": {k: str(v) for k, v in fields.items()}}})


def respond(req_id: str, result: Any) -> None:
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str) -> None:
    emit({"id": req_id, "error": {"code": code, "message": message}})


# --- config -------------------------------------------------------------

def build_config() -> FaceTrackerConfig:
    intrinsics = CameraIntrinsics(
        hfov_deg=float(os.environ.get("ROCKY_FT_HFOV_DEG", 65.0)),
        vfov_deg=float(os.environ.get("ROCKY_FT_VFOV_DEG", 39.0)),
    )
    return FaceTrackerConfig(
        intrinsics=intrinsics,
        ema_alpha=float(os.environ.get("ROCKY_FT_EMA_ALPHA", 0.5)),
        damper_omega=float(os.environ.get("ROCKY_FT_DAMPER_OMEGA", 3.0)),
        idle_timeout_s=float(os.environ.get("ROCKY_FT_IDLE_TIMEOUT_S", 1.5)),
    )


# --- main ---------------------------------------------------------------

class Runner:
    def __init__(self) -> None:
        self.cfg = build_config()
        self.controller = FaceTrackerController(self.cfg)
        self.mode = os.environ.get("ROCKY_FT_MODE", "synthetic").lower()
        self.prompt = os.environ.get("ROCKY_FT_PROMPT", "a brunette male with a beard")
        self.enabled = True
        self.shutdown_flag = threading.Event()

        if self.mode == "synthetic":
            self.detector = SyntheticDetector(syn_from_env(), prompt_id=self.prompt)
        else:
            # Real-robot mode (M3b): SAM 3.1 + Reachy SDK camera. Stub for now.
            log("warn", "non-synthetic detector not yet implemented", mode=self.mode)
            self.detector = SyntheticDetector(syn_from_env(), prompt_id=self.prompt)

    # --- threads ---

    def detector_loop(self) -> None:
        log("info", "detector thread up", mode=self.mode)
        # Detector ticks at ~10 Hz in synthetic mode (matches roughly what
        # SAM 3.1 produces on M-series at 448 px).
        while not self.shutdown_flag.is_set():
            if self.enabled:
                det = self.detector.step()
                if det is not None and self.controller.ingest_detection(det):
                    emit({
                        "event": "detection",
                        "payload": {
                            "bbox": list(det.bbox_xywh),
                            "confidence": det.confidence,
                            "frame_w": det.frame_w,
                            "frame_h": det.frame_h,
                            "prompt_id": det.prompt_id,
                        },
                    })
            time.sleep(0.1)

    def command_loop(self) -> None:
        log("info", "command thread up", hz=50)
        period = 1.0 / 50.0
        last = time.monotonic()
        while not self.shutdown_flag.is_set():
            now = time.monotonic()
            dt = now - last
            last = now
            if not self.enabled:
                time.sleep(period)
                continue
            yaw, pitch, decay = self.controller.tick(dt, now=now)
            emit({
                "event": "target",
                "payload": {
                    "yaw_rad": yaw,
                    "pitch_rad": pitch,
                    "decay_active": decay,
                },
            })
            slack = period - (time.monotonic() - now)
            if slack > 0:
                time.sleep(slack)

    # --- request dispatch ---

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if rid is None or not method:
            return

        try:
            if method == "set_enabled":
                self.enabled = bool(params.get("enabled", True))
                respond(rid, {"enabled": self.enabled})
            elif method == "set_prompt":
                self.prompt = str(params.get("text", self.prompt))
                respond(rid, {"prompt": self.prompt})
            elif method == "update_commanded_pose":
                self.controller.update_commanded_pose(
                    yaw_rad=float(params.get("yaw_rad", 0.0)),
                    pitch_rad=float(params.get("pitch_rad", 0.0)),
                )
                respond(rid, {"ok": True})
            elif method == "health":
                respond(rid, {
                    "mode": self.mode,
                    "enabled": self.enabled,
                    "prompt": self.prompt,
                })
            elif method == "shutdown":
                self.shutdown_flag.set()
                respond(rid, {"ok": True})
            else:
                respond_error(rid, 404, f"unknown method: {method}")
        except Exception as exc:  # noqa: BLE001
            respond_error(rid, 500, f"{type(exc).__name__}: {exc}")

    def serve_stdin(self) -> None:
        for line in sys.stdin:
            if self.shutdown_flag.is_set():
                break
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError as exc:
                log("error", "bad json", error=str(exc), line=line[:200])
                continue
            self.handle(req)


def main() -> None:
    runner = Runner()
    log("info", "face-tracker starting",
        mode=runner.mode, prompt=runner.prompt,
        damper_omega=runner.cfg.damper_omega,
        ema_alpha=runner.cfg.ema_alpha)
    emit({"event": "ready"})

    threading.Thread(target=runner.detector_loop, name="detector", daemon=True).start()
    threading.Thread(target=runner.command_loop, name="command", daemon=True).start()

    try:
        runner.serve_stdin()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        runner.shutdown_flag.set()


if __name__ == "__main__":
    main()
