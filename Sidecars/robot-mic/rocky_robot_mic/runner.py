"""Robot-mic sidecar entry point.

Pulls audio from the Reachy Mini onboard microphone array via the
`reachy_mini` SDK (auto-uses WebRTC when run remotely from the Mac) and
emits PCM chunks as line-delimited JSON events.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
from typing import Any, Optional

import numpy as np


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
    # Audio loop stall detection. If `recording` is true but no frames
    # have flowed for this long, exit the process so the SidecarHost
    # supervisor restarts us with a fresh WebRTC connection. This is
    # the difference between "mic is unreliable" (silent freezes) and
    # "mic is offline for 7 seconds and then comes back".
    STALL_TIMEOUT_S = 5.0

    def __init__(self) -> None:
        self.host = os.environ.get("ROCKY_ROBOT_HOST", "reachy-mini.local")
        self.port = int(os.environ.get("ROCKY_ROBOT_PORT", "8000"))
        self.recording = False
        self.shutdown_flag = threading.Event()
        self.mini = None
        self.sample_rate: int = 16_000
        self.channels: int = 1
        self.last_doa_emit_ts: float = 0.0
        self.last_frame_ts: float = time.monotonic()

        # Connect on the MAIN thread before stdin loop. GStreamer's GLib
        # main-loop integration is finicky from a background thread, which
        # caused silent hangs in earlier builds.
        from reachy_mini import ReachyMini

        log("info", "connecting to robot", host=self.host, port=self.port)
        self.mini = ReachyMini(
            host=self.host, port=self.port,
            connection_mode="network", media_backend="webrtc",
            automatic_body_yaw=False,
            log_level="WARNING",
        )
        log("info", "connected to robot")

    # --- audio streaming ---

    def audio_loop(self) -> None:
        assert self.mini is not None
        self.mini.media.start_recording()
        try:
            self.sample_rate = int(self.mini.media.get_input_audio_samplerate() or 16_000)
            self.channels = int(self.mini.media.get_input_channels() or 1)
        except Exception:
            pass

        log("info", "recording started",
            sr=self.sample_rate, ch=self.channels)
        # Start the stall watchdog only once recording is live.
        self.last_frame_ts = time.monotonic()
        threading.Thread(target=self._stall_watchdog,
                         name="stall-watchdog", daemon=True).start()

        # Reachy Mini's mic array delivers float32 stereo at 16 kHz; we
        # downmix to mono and emit ~30-50 Hz worth of PCM at a time.
        while not self.shutdown_flag.is_set() and self.recording:
            try:
                samples = self.mini.media.get_audio_sample()
            except Exception as exc:
                log("warn", "get_audio_sample failed", error=str(exc))
                time.sleep(0.05)
                continue
            if samples is None or len(samples) == 0:
                time.sleep(0.005)
                continue

            # samples: shape (N, 2) float32 typically
            arr = np.asarray(samples, dtype=np.float32)
            if arr.ndim == 2 and arr.shape[1] >= 1:
                mono = arr.mean(axis=1)
            else:
                mono = arr.reshape(-1)

            # Convert to int16 for compact transit
            clipped = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
            data_b64 = base64.b64encode(clipped.tobytes()).decode("ascii")
            rms = float(np.sqrt(np.mean(mono * mono))) if mono.size else 0.0

            emit({
                "event": "audio",
                "payload": {
                    "samples_b64": data_b64,
                    "sample_rate": self.sample_rate,
                    "channels": 1,
                    "rms": rms,
                },
            })
            self.last_frame_ts = time.monotonic()

            # DoA at most once per 200 ms when speech is present
            now = time.monotonic()
            if now - self.last_doa_emit_ts >= 0.2:
                try:
                    doa = self.mini.media.get_DoA()
                    if doa is not None:
                        angle, is_speech = doa
                        emit({
                            "event": "doa",
                            "payload": {
                                "angle_rad": float(angle),
                                "is_speech": bool(is_speech),
                            },
                        })
                        self.last_doa_emit_ts = now
                except Exception:
                    pass

        try:
            self.mini.media.stop_recording()
        except Exception:
            pass
        log("info", "recording stopped")

    def _stall_watchdog(self) -> None:
        """Exit the process if `recording` is true but no audio frames
        have arrived for `STALL_TIMEOUT_S`. Triggers when the bot's
        media has been released externally, when WebRTC silently
        drops, or when GStreamer's pipeline deadlocks. The
        SidecarSupervisor on the Swift side will respawn us with a
        fresh ReachyMini connection — much faster recovery than
        waiting for someone to notice the mic is dead."""
        while not self.shutdown_flag.is_set():
            time.sleep(1.0)
            if not self.recording:
                self.last_frame_ts = time.monotonic()
                continue
            stalled = time.monotonic() - self.last_frame_ts
            if stalled > self.STALL_TIMEOUT_S:
                log("error", "audio stalled, exiting for restart",
                    stalled_s=f"{stalled:.1f}")
                # Hard exit — the supervisor's restart_policy=on_failure
                # will respawn us and audio resumes within ~1s.
                os._exit(1)

    # --- request dispatch ---

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if rid is None or not method:
            return

        try:
            if method == "start_recording":
                if not self.recording:
                    self.recording = True
                    threading.Thread(target=self.audio_loop, name="audio",
                                     daemon=True).start()
                respond(rid, {"recording": True})
            elif method == "stop_recording":
                self.recording = False
                respond(rid, {"recording": False})
            elif method == "health":
                respond(rid, {
                    "connected": self.mini is not None,
                    "recording": self.recording,
                    "sample_rate": self.sample_rate,
                    "channels": self.channels,
                    "host": self.host,
                    "port": self.port,
                })
            elif method == "shutdown":
                self.shutdown_flag.set()
                self.recording = False
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
    log("info", "robot-mic starting", host=os.environ.get("ROCKY_ROBOT_HOST", "?"))
    try:
        runner = Runner()
    except Exception as exc:  # noqa: BLE001
        log("error", "init failed", error=str(exc))
        # Still emit ready so SidecarHost doesn't time out; subsequent
        # method calls will return errors with the actual reason.
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
        runner.recording = False


if __name__ == "__main__":
    main()
