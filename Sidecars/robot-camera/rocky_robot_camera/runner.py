"""Robot camera sidecar entry point."""

from __future__ import annotations

import base64
import io
import json
import os
import sys
import threading
import time
from typing import Any

import numpy as np
from PIL import Image


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


class Runner:
    def __init__(self) -> None:
        self.host = os.environ.get("ROCKY_ROBOT_HOST", "reachy-mini.local")
        self.port = int(os.environ.get("ROCKY_ROBOT_PORT", "8000"))
        self.fps = float(os.environ.get("ROCKY_CAM_FPS", "10"))
        self.target_width = int(os.environ.get("ROCKY_CAM_WIDTH", "480"))
        self.jpeg_quality = int(os.environ.get("ROCKY_CAM_QUALITY", "65"))
        self.streaming = False
        self.shutdown_flag = threading.Event()
        self.frame_seq = 0

        # Connect on the MAIN thread before stdin loop. GStreamer's GLib
        # main-loop integration is finicky from a background thread.
        from reachy_mini import ReachyMini

        log("info", "connecting to robot",
            host=self.host, port=self.port, fps=self.fps)
        self.mini = ReachyMini(
            host=self.host, port=self.port,
            connection_mode="network", media_backend="webrtc",
            automatic_body_yaw=False,
            log_level="WARNING",
        )
        self._acquire_media()
        log("info", "connected to robot")

    def _acquire_media(self) -> bool:
        """Try to acquire camera/audio media from the daemon. Idempotent."""
        try:
            self.mini.acquire_media()
            log("info", "media acquired")
            return True
        except Exception as exc:  # noqa: BLE001
            log("warn", "acquire_media failed", error=str(exc))
            return False

    def _refresh_media(self) -> bool:
        """Best-effort `acquire_media` to nudge a silently-dropped
        WebRTC peer back. We do NOT call `release_media` here —
        the bot's media lock is shared with the mic sidecar, and
        releasing it on a transient stall would tear down the
        mic's peer too. `acquire_media` alone is idempotent: a
        no-op when healthy, a re-arm when the daemon has
        half-dropped. If the SDK's internal state is genuinely
        broken, the fatal-exit tier respawns us with a clean
        instance."""
        return self._acquire_media()

    def stream_loop(self) -> None:
        log("info", "frame stream started",
            target_width=self.target_width, jpeg_quality=self.jpeg_quality)
        period = 1.0 / max(1.0, self.fps)
        last_emit = 0.0
        last_success = time.monotonic()
        last_health_log = time.monotonic()
        last_refresh = 0.0
        consecutive_none = 0
        was_stale = False

        # Tunables — keep conservative.
        STALE_REFRESH_S = float(os.environ.get("ROCKY_CAM_STALE_REFRESH_S", "3"))
        FATAL_S = float(os.environ.get("ROCKY_CAM_FATAL_S", "20"))
        HEALTH_LOG_PERIOD_S = 5.0
        REFRESH_COOLDOWN_S = 8.0

        while not self.shutdown_flag.is_set() and self.streaming:
            now = time.monotonic()
            if now - last_emit < period:
                time.sleep(0.005)
                continue

            staleness = now - last_success

            # Periodic health log so the user can see what's happening.
            if now - last_health_log > HEALTH_LOG_PERIOD_S:
                log("debug", "camera health",
                    frames=self.frame_seq, stale_s=f"{staleness:.1f}",
                    consecutive_none=consecutive_none)
                last_health_log = now

            # If staleness exceeds threshold, try to refresh the WebRTC
            # connection by releasing + re-acquiring media. Cooldown to
            # avoid hammering on a totally broken connection.
            if staleness > STALE_REFRESH_S and now - last_refresh > REFRESH_COOLDOWN_S:
                log("warn", "camera stale — refreshing media",
                    stale_s=f"{staleness:.1f}")
                self._refresh_media()
                last_refresh = now
                # Don't reset last_success; if refresh works the next
                # successful frame will reset it naturally.

            # If staleness exceeds the fatal threshold, exit non-zero.
            # The supervisor will restart this sidecar with fresh state.
            if staleness > FATAL_S:
                log("error", "camera dead — exiting for supervisor restart",
                    stale_s=f"{staleness:.1f}")
                sys.exit(2)

            try:
                frame = self.mini.media.get_frame()
            except Exception as exc:
                log("warn", "get_frame failed", error=str(exc))
                time.sleep(0.05)
                continue

            if frame is None:
                consecutive_none += 1
                time.sleep(0.01)
                continue

            try:
                arr = np.asarray(frame, dtype=np.uint8)
            except Exception as exc:  # noqa: BLE001
                log("warn", "asarray failed", error=str(exc))
                time.sleep(0.05)
                continue

            if arr.ndim != 3 or arr.shape[2] != 3:
                log("warn", "unexpected frame shape", shape=str(arr.shape))
                time.sleep(0.05)
                continue
            h, w, _ = arr.shape

            scale = self.target_width / float(w)
            new_w = self.target_width
            new_h = max(1, int(h * scale))
            try:
                pil = Image.fromarray(arr)
                pil = pil.resize((new_w, new_h), Image.BILINEAR)
                buf = io.BytesIO()
                pil.save(buf, format="JPEG", quality=self.jpeg_quality, optimize=False)
                jpeg = buf.getvalue()
            except Exception as exc:
                log("warn", "encode failed", error=str(exc))
                time.sleep(0.05)
                continue

            # Recovery message — emit once per regression.
            if was_stale:
                log("info", "camera recovered",
                    after_stale_s=f"{staleness:.1f}")
                was_stale = False
            elif staleness > STALE_REFRESH_S:
                was_stale = True

            self.frame_seq += 1
            consecutive_none = 0
            last_success = now
            emit({
                "event": "frame",
                "payload": {
                    "seq": self.frame_seq,
                    "width": new_w,
                    "height": new_h,
                    "jpeg_b64": base64.b64encode(jpeg).decode("ascii"),
                    "source_width": w,
                    "source_height": h,
                },
            })
            last_emit = now

        log("info", "frame stream stopped",
            total_frames=self.frame_seq)

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if rid is None or not method:
            return

        try:
            if method == "start_streaming":
                if not self.streaming:
                    self.streaming = True
                    threading.Thread(target=self.stream_loop, name="camera",
                                     daemon=True).start()
                respond(rid, {"streaming": True})
            elif method == "stop_streaming":
                self.streaming = False
                respond(rid, {"streaming": False})
            elif method == "set_fps":
                self.fps = float(params.get("fps", self.fps))
                respond(rid, {"fps": self.fps})
            elif method == "health":
                respond(rid, {
                    "streaming": self.streaming,
                    "fps": self.fps,
                    "target_width": self.target_width,
                    "frame_seq": self.frame_seq,
                    "host": self.host,
                    "port": self.port,
                })
            elif method == "shutdown":
                self.shutdown_flag.set()
                self.streaming = False
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
    log("info", "robot-camera starting",
        host=os.environ.get("ROCKY_ROBOT_HOST", "?"))
    try:
        runner = Runner()
    except Exception as exc:  # noqa: BLE001
        log("error", "init failed", error=str(exc))
        emit({"event": "ready"})
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                continue
            rid = req.get("id")
            if rid:
                respond_error(rid, 503, f"sidecar init failed: {exc}")
        return

    emit({"event": "ready"})
    try:
        runner.serve_stdin()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        runner.shutdown_flag.set()
        runner.streaming = False


if __name__ == "__main__":
    main()
