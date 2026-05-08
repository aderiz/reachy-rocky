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
    # Three-tier stall recovery. Each tier is more invasive than
    # the last; the goal is to absorb most stalls invisibly without
    # going to process respawn (which trips the supervisor's circuit
    # breaker after 3 restarts/minute and locks the mic out for 60 s).
    #
    # 1. T1 — soft refresh at STALL_REFRESH_S: `release_media +
    #    acquire_media`. Most transient WebRTC hiccups recover here.
    # 2. T2 — in-process SDK reconnect at STALL_RECONNECT_S: tear
    #    down ReachyMini and recreate it without exiting. Fresh
    #    WebRTC peer without supervisor involvement.
    # 3. T3 — fatal exit at STALL_FATAL_S: release media cleanly
    #    so the bot's WebRTC peer state is freed, then `os._exit(1)`
    #    so the supervisor respawns us with a clean slate.
    #
    # Timeouts are deliberately patient. WebRTC re-negotiations can
    # take 10–20 s to settle on their own; firing too aggressively
    # interrupts natural recovery and compounds the problem.
    STALL_REFRESH_S = 5.0
    STALL_RECONNECT_S = 12.0
    STALL_FATAL_S = 30.0
    REFRESH_COOLDOWN_S = 8.0
    RECONNECT_COOLDOWN_S = 15.0

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
        self._watchdog_thread: threading.Thread | None = None
        self._audio_thread: threading.Thread | None = None
        # Serialises every operation that mutates `self.mini` or
        # invokes a multi-step SDK call against it. Without this,
        # the audio thread (`mini.media.get_audio_sample`), the
        # main stdin thread (`mini.media.start_recording`), and the
        # watchdog (`_refresh_media` / `_reconnect_sdk` reassigning
        # `self.mini`) can observe two different SDK instances mid-
        # operation. Held briefly during reassignments; not held
        # during long blocking calls.
        self._mini_lock = threading.Lock()

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
        self.last_frame_ts = time.monotonic()
        # Spawn the stall watchdog at most once per process — a
        # reconnect-tier recovery restarts audio_loop, but we don't
        # want a second watchdog stacking on the first.
        if self._watchdog_thread is None or not self._watchdog_thread.is_alive():
            self._watchdog_thread = threading.Thread(
                target=self._stall_watchdog,
                name="stall-watchdog",
                daemon=True,
            )
            self._watchdog_thread.start()

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
        """T1 — best-effort `release_media + acquire_media` on the
        bot. Many WebRTC drops recover with a refresh and never need
        a deeper recovery. Returns True if reacquisition succeeded."""
        with self._mini_lock:
            mini = self.mini
        if mini is None:
            return False
        try:
            mini.release_media()
            log("info", "media released for refresh")
        except Exception as exc:  # noqa: BLE001
            log("debug", "release_media skipped", error=str(exc))
        time.sleep(0.3)
        try:
            mini.acquire_media()
            log("info", "media reacquired")
            return True
        except Exception as exc:  # noqa: BLE001
            log("warn", "acquire_media failed", error=str(exc))
            return False

    def _reconnect_sdk(self) -> bool:
        """T2 — tear down ReachyMini and recreate it without exiting.
        Avoids the supervisor circuit breaker (3 restarts/min →
        60 s cooldown) and gives a fresh WebRTC peer without leaving
        stale state on the bot. Returns True if the new SDK
        connected and media was acquired."""
        # Stop the current audio loop and wait for it to exit. We
        # capture the thread reference up-front so we can `join()`
        # — the previous version's blind 0.5 s sleep meant a slow
        # audio loop iteration could still be holding the OLD
        # `self.mini` reference when we reassigned it, and the
        # restart could spawn a SECOND concurrent audio loop.
        self.recording = False
        old_thread = self._audio_thread
        if old_thread is not None and old_thread.is_alive():
            old_thread.join(timeout=2.0)
            if old_thread.is_alive():
                log("warn", "audio thread did not exit within 2s")

        with self._mini_lock:
            old_mini = self.mini
            self.mini = None

        try:
            old_mini.release_media()  # type: ignore[union-attr]
        except Exception as exc:  # noqa: BLE001
            log("debug", "release_media during reconnect failed",
                error=str(exc))

        try:
            from reachy_mini import ReachyMini
            new_mini = ReachyMini(
                host=self.host, port=self.port,
                connection_mode="network", media_backend="webrtc",
                automatic_body_yaw=False,
                log_level="WARNING",
            )
            new_mini.acquire_media()
        except Exception as exc:  # noqa: BLE001
            log("error", "SDK reconnect failed", error=str(exc))
            return False

        with self._mini_lock:
            self.mini = new_mini

        # Grace period — WebRTC re-negotiation can take a few
        # seconds to produce its first frame. Without offsetting
        # `last_frame_ts` into the future, the watchdog wakes up
        # right after reconnect and immediately re-trips T1.
        self.last_frame_ts = time.monotonic() + 5.0
        self.recording = True
        self._audio_thread = threading.Thread(
            target=self.audio_loop, name="audio", daemon=True
        )
        self._audio_thread.start()
        log("info", "SDK reconnected in-process")
        return True

    def _stall_watchdog(self) -> None:
        """Three-tier stall recovery for the audio loop. Most invasive
        tier checked first — `if/elif` so a single watchdog tick
        never fires multiple tiers (the previous code could T1+T2
        in the same iteration, with T2 destroying the SDK that T1
        had just refreshed). Cooldowns prevent hammering on a
        connection that needs more time to recover."""
        last_refresh = 0.0
        last_reconnect = 0.0
        while not self.shutdown_flag.is_set():
            time.sleep(1.0)
            if not self.recording:
                self.last_frame_ts = time.monotonic()
                continue
            now = time.monotonic()
            stalled = now - self.last_frame_ts

            if stalled > self.STALL_FATAL_S:
                # T3 — fatal exit with cleanup. Releasing media
                # before `os._exit` matters: a hard exit without
                # it leaves a half-connected WebRTC peer on the
                # bot, and every subsequent respawn inherits the
                # corruption.
                log("error", "audio dead — exiting for supervisor restart",
                    stalled_s=f"{stalled:.1f}")
                try:
                    with self._mini_lock:
                        if self.mini is not None:
                            self.mini.release_media()
                except Exception:  # noqa: BLE001
                    pass
                os._exit(1)
            elif (stalled > self.STALL_RECONNECT_S
                  and now - last_reconnect > self.RECONNECT_COOLDOWN_S):
                # T2 — in-process SDK reconnect.
                log("warn", "audio still stalled — reconnecting SDK in-process",
                    stalled_s=f"{stalled:.1f}")
                self._reconnect_sdk()
                last_reconnect = now
            elif (stalled > self.STALL_REFRESH_S
                  and now - last_refresh > self.REFRESH_COOLDOWN_S):
                # T1 — soft media refresh.
                log("warn", "audio stalled — refreshing media",
                    stalled_s=f"{stalled:.1f}")
                self._refresh_media()
                last_refresh = now

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
                    self._audio_thread = threading.Thread(
                        target=self.audio_loop, name="audio", daemon=True
                    )
                    self._audio_thread.start()
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
