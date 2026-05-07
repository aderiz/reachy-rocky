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
        # Camera frames stay None until media is explicitly acquired.
        try:
            self.mini.acquire_media()
            log("info", "media acquired")
        except Exception as exc:  # noqa: BLE001
            log("warn", "acquire_media failed", error=str(exc))
        log("info", "connected to robot")

    def stream_loop(self) -> None:
        log("info", "frame stream started",
            target_width=self.target_width, jpeg_quality=self.jpeg_quality)
        period = 1.0 / max(1.0, self.fps)
        last_emit = 0.0
        while not self.shutdown_flag.is_set() and self.streaming:
            now = time.monotonic()
            if now - last_emit < period:
                time.sleep(0.005)
                continue

            try:
                frame = self.mini.media.get_frame()
            except Exception as exc:
                log("warn", "get_frame failed", error=str(exc))
                time.sleep(0.05)
                continue
            if frame is None:
                time.sleep(0.01)
                continue

            arr = np.asarray(frame, dtype=np.uint8)
            if arr.ndim != 3 or arr.shape[2] != 3:
                log("warn", "unexpected frame shape", shape=str(arr.shape))
                time.sleep(0.05)
                continue
            h, w, _ = arr.shape

            # Downsample to target width preserving aspect ratio.
            scale = self.target_width / float(w)
            new_w = self.target_width
            new_h = max(1, int(h * scale))
            try:
                # Frames from reachy_mini are typically RGB. If they're BGR
                # we'd see swapped colors but otherwise valid output.
                pil = Image.fromarray(arr)
                pil = pil.resize((new_w, new_h), Image.BILINEAR)
                buf = io.BytesIO()
                pil.save(buf, format="JPEG", quality=self.jpeg_quality, optimize=False)
                jpeg = buf.getvalue()
            except Exception as exc:
                log("warn", "encode failed", error=str(exc))
                time.sleep(0.05)
                continue

            self.frame_seq += 1
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

        log("info", "frame stream stopped")

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
