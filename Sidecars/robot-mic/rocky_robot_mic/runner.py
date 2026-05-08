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
    # Two-tier stall recovery, mirroring the camera sidecar:
    #
    # 1. After `STALL_REFRESH_S` of no frames, try a soft refresh:
    #    `release_media + acquire_media`. Most WebRTC drops on the
    #    bot side recover from this without a full process respawn.
    # 2. After `STALL_FATAL_S` of no frames (regardless of refresh
    #    attempts), exit the process so the SidecarHost supervisor
    #    respawns us with a brand-new ReachyMini connection. The
    #    cooldown between refreshes prevents hammering on a totally
    #    broken connection.
    STALL_REFRESH_S = 3.0
    STALL_FATAL_S = 12.0
    REFRESH_COOLDOWN_S = 6.0

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

    def _refresh_media(self) -> bool:
        """Best-effort `release_media + acquire_media` on the bot.
        Many WebRTC drops recover with a refresh and never need a
        process restart. Returns True if reacquisition succeeded."""
        try:
            self.mini.release_media()
            log("info", "media released for refresh")
        except Exception as exc:  # noqa: BLE001
            log("debug", "release_media skipped", error=str(exc))
        time.sleep(0.3)
        try:
            self.mini.acquire_media()
            log("info", "media reacquired")
            return True
        except Exception as exc:  # noqa: BLE001
            log("warn", "acquire_media failed", error=str(exc))
            return False

    def _stall_watchdog(self) -> None:
        """Two-tier stall recovery for the audio loop. Soft refresh
        first (release+reacquire media) so transient WebRTC drops
        don't require a process respawn. Hard exit only if the soft
        refresh hasn't restored frames within `STALL_FATAL_S`."""
        last_refresh = 0.0
        while not self.shutdown_flag.is_set():
            time.sleep(1.0)
            if not self.recording:
                self.last_frame_ts = time.monotonic()
                continue
            now = time.monotonic()
            stalled = now - self.last_frame_ts

            # Tier 1: soft media refresh, rate-limited so we don't
            # hammer on a fully broken connection.
            if (stalled > self.STALL_REFRESH_S
                and now - last_refresh > self.REFRESH_COOLDOWN_S):
                log("warn", "audio stalled, refreshing media",
                    stalled_s=f"{stalled:.1f}")
                self._refresh_media()
                last_refresh = now
                # Don't reset last_frame_ts — the next real frame
                # resets it naturally and we want the fatal timer
                # to keep counting from the original stall.

            # Tier 2: fatal exit, supervisor respawns us.
            if stalled > self.STALL_FATAL_S:
                log("error", "audio dead, exiting for supervisor restart",
                    stalled_s=f"{stalled:.1f}")
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
