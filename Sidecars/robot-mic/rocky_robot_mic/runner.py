"""Robot-mic sidecar entry point (v0.2 — WebSocket subscriber).

Connects to the on-bot `rocky_media_relay` Reachy Mini App over a
plain WebSocket and republishes audio + DoA events to the Swift side
in the existing SidecarHost JSON-line envelope. The Swift adapter
(`RobotMicService`) sees no protocol change — only the underlying
transport between bot and Mac is now WebSocket instead of WebRTC.

Why the swap: the WebRTC-over-WiFi path was dropping its signalling
channel repeatedly, leaving the sidecar in a respawn cycle and
producing silent / zero-valued PCM for stretches. The on-bot relay
captures via the SDK's LOCAL media backend (IPC + direct GStreamer)
and pushes plain JSON-framed PCM over WS — a TCP transport that
doesn't need DTLS / ICE / signalling.

Stdin RPCs (unchanged):
  start_recording → POST /control/start_recording on the bot relay,
                    open the audio WS subscription if not already up.
  stop_recording  → POST /control/stop_recording. Audio WS stays
                    open so re-starting is fast.
  health          → returns connection + counters.
  shutdown        → graceful exit.

Stdout events (unchanged):
  ready  — once the sidecar has acquired the bot relay connection.
  audio  — { samples_b64, sample_rate, channels, rms }
  doa    — { angle_rad, is_speech }
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import sys
import threading
import time
from typing import Any
from urllib.parse import urljoin
from urllib.request import Request, urlopen

import numpy as np


# ---------------------------------------------------------------------------
# Wire I/O — same envelopes as before.
# ---------------------------------------------------------------------------


_io_lock = threading.Lock()


def emit(obj: dict[str, Any]) -> None:
    line = json.dumps(obj)
    with _io_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(level: str, msg: str, **fields: Any) -> None:
    emit({"log": {"level": level, "msg": msg,
                  "fields": {k: str(v) for k, v in fields.items()}}})


def respond(req_id: str, result: Any) -> None:
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str) -> None:
    emit({"id": req_id, "error": {"code": code, "message": message}})


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[robot-mic] {msg}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Bot relay config
# ---------------------------------------------------------------------------


# `rocky_media_relay`'s custom_app_url is `http://0.0.0.0:8042` on the
# bot. From the Mac we reach it at the bot's hostname + that port.
DEFAULT_HOST = os.environ.get("ROCKY_ROBOT_HOST", "reachy-mini.local")
RELAY_PORT = int(os.environ.get("ROCKY_RELAY_PORT", "8042"))
HTTP_BASE = f"http://{DEFAULT_HOST}:{RELAY_PORT}"
WS_URL = f"ws://{DEFAULT_HOST}:{RELAY_PORT}/ws/audio"


# ---------------------------------------------------------------------------
# Subscriber — single asyncio loop in a dedicated thread.
# ---------------------------------------------------------------------------


class RelaySubscriber:
    """Owns the WebSocket connection to the bot relay. Runs in its
    own asyncio loop on a background thread so the stdin dispatch
    thread (which is synchronous) stays simple."""

    RECONNECT_BACKOFF_S = (1.0, 2.0, 5.0, 10.0)

    def __init__(self) -> None:
        self.shutdown = threading.Event()
        self.connected = threading.Event()
        self.sample_rate = 16_000
        self.channels = 1
        self.last_rms: float = 0.0
        self._loop: asyncio.AbstractEventLoop | None = None
        self._task: asyncio.Task | None = None
        self._thread = threading.Thread(
            target=self._thread_entry, name="ws-subscriber", daemon=True
        )
        self._logged_first_frame = False
        self._peak_log_ts = 0.0
        self._window_peak = 0.0

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self.shutdown.set()
        loop = self._loop
        if loop is not None:
            loop.call_soon_threadsafe(loop.stop)

    # ---- thread / asyncio plumbing ----

    def _thread_entry(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._supervise())
        except Exception as exc:  # noqa: BLE001
            _stderr(f"supervisor crashed: {exc}")
        finally:
            try:
                self._loop.close()
            except Exception:
                pass

    async def _supervise(self) -> None:
        """Reconnect loop. Exponential-ish backoff; cancellable
        cleanly when shutdown is requested."""
        attempt = 0
        while not self.shutdown.is_set():
            try:
                await self._connect_once()
                attempt = 0  # successful run; reset backoff
            except asyncio.CancelledError:
                break
            except Exception as exc:  # noqa: BLE001
                wait = self.RECONNECT_BACKOFF_S[min(
                    attempt, len(self.RECONNECT_BACKOFF_S) - 1
                )]
                _stderr(f"ws disconnected ({type(exc).__name__}: {exc}); "
                        f"reconnect in {wait}s")
                self.connected.clear()
                attempt += 1
                # interruptible sleep
                for _ in range(int(wait * 10)):
                    if self.shutdown.is_set():
                        return
                    await asyncio.sleep(0.1)

    async def _connect_once(self) -> None:
        # Lazy import so a missing `websockets` dep surfaces here
        # rather than at module load.
        import websockets

        _stderr(f"connecting to {WS_URL}")
        async with websockets.connect(
            WS_URL,
            ping_interval=10,
            ping_timeout=20,
            max_size=None,  # video frames can be ~30 KB; relay sends
                            # audio chunks of ~1 KB — no useful cap.
            close_timeout=5,
        ) as ws:
            self.connected.set()
            _stderr(f"ws connected to {WS_URL}")
            try:
                async for raw in ws:
                    self._handle_message(raw)
            finally:
                self.connected.clear()

    def _handle_message(self, raw) -> None:
        # `websockets` yields bytes for binary frames, str for text.
        # The relay sends one envelope as `ws.send_bytes` (utf-8 JSON
        # line) per message; the hello frame is `send_text`.
        if isinstance(raw, (bytes, bytearray)):
            try:
                text = raw.decode("utf-8").rstrip("\n")
            except UnicodeDecodeError:
                _stderr("dropping non-utf8 binary message")
                return
        else:
            text = raw.rstrip("\n") if isinstance(raw, str) else ""
        if not text:
            return
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            return
        t = obj.get("type")
        if t == "audio":
            self._handle_audio(obj)
        elif t == "doa":
            self._handle_doa(obj)
        elif t == "hello":
            sr = obj.get("sr")
            if isinstance(sr, int):
                self.sample_rate = sr
            ch = obj.get("ch")
            if isinstance(ch, int):
                self.channels = ch
            _stderr(f"hello: sr={self.sample_rate} ch={self.channels} "
                    f"build={obj.get('build')}")

    def _handle_audio(self, obj: dict[str, Any]) -> None:
        pcm_b64 = obj.get("pcm_b64")
        sr = obj.get("sr") or self.sample_rate
        rms = float(obj.get("rms") or 0.0)
        if not isinstance(pcm_b64, str):
            return
        # Re-emit on the SAME wire envelope the Swift side already
        # consumes — `samples_b64` int16 LE mono at 16 kHz, plus rms.
        # No transformation: the relay already produced int16 mono.
        emit({
            "event": "audio",
            "payload": {
                "samples_b64": pcm_b64,
                "sample_rate": int(sr),
                "channels": 1,
                "rms": rms,
            },
        })
        self.sample_rate = int(sr)
        self.last_rms = rms

        # Periodic peak instrumentation — same shape as the v0.1
        # WebRTC sidecar so the terminal log surface is unchanged.
        # We decode just enough to compute peak; the bot already
        # computed RMS so we don't recompute that.
        if not self._logged_first_frame or (time.monotonic() - self._peak_log_ts) >= 1.0:
            try:
                pcm = base64.b64decode(pcm_b64)
                i16 = np.frombuffer(pcm, dtype="<i2")
                peak_i = int(np.max(np.abs(i16))) if i16.size else 0
                peak = peak_i / 32768.0
            except Exception:
                peak = 0.0
            if peak > self._window_peak:
                self._window_peak = peak
            now = time.monotonic()
            if not self._logged_first_frame:
                self._logged_first_frame = True
                _stderr(f"first audio frame sr={sr} samples={len(pcm_b64) // 4 * 3} "
                        f"peak={peak:.5f}")
                self._peak_log_ts = now
            elif now - self._peak_log_ts >= 1.0:
                _stderr(f"peak (last 1s) = {self._window_peak:.5f}")
                self._window_peak = 0.0
                self._peak_log_ts = now

    def _handle_doa(self, obj: dict[str, Any]) -> None:
        angle = obj.get("angle_rad")
        is_speech = obj.get("is_speech")
        if angle is None:
            return
        emit({
            "event": "doa",
            "payload": {
                "angle_rad": float(angle),
                "is_speech": bool(is_speech),
            },
        })


# ---------------------------------------------------------------------------
# Synchronous HTTP control plane (start/stop recording on bot)
# ---------------------------------------------------------------------------


def _post(path: str, timeout: float = 5.0) -> dict[str, Any]:
    url = urljoin(HTTP_BASE + "/", path.lstrip("/"))
    req = Request(url, data=b"", method="POST")
    with urlopen(req, timeout=timeout) as resp:
        body = resp.read()
        if not body:
            return {}
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}


# ---------------------------------------------------------------------------
# Runner — dispatch loop on stdin
# ---------------------------------------------------------------------------


class Runner:
    def __init__(self) -> None:
        self.subscriber = RelaySubscriber()
        self.subscriber.start()
        # Block briefly so the supervisor's `ready` envelope reflects
        # whether the WS came up. We don't WAIT_FOR_CONNECT — the
        # bot relay may be down at first launch and that's fine; we
        # just emit ready and let reconnects continue in background.
        self.subscriber.connected.wait(timeout=2.0)
        self.recording = False
        log("info", "robot-mic starting", host=DEFAULT_HOST, port=str(RELAY_PORT))

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        if rid is None or not method:
            return
        try:
            if method == "start_recording":
                _post("/control/start_recording")
                self.recording = True
                respond(rid, {"recording": True})
            elif method == "stop_recording":
                _post("/control/stop_recording")
                self.recording = False
                respond(rid, {"recording": False})
            elif method == "health":
                respond(rid, {
                    "connected": self.subscriber.connected.is_set(),
                    "recording": self.recording,
                    "sample_rate": self.subscriber.sample_rate,
                    "channels": self.subscriber.channels,
                    "host": DEFAULT_HOST,
                    "port": RELAY_PORT,
                    "transport": "websocket",
                })
            elif method == "shutdown":
                self.subscriber.stop()
                self.recording = False
                respond(rid, {"ok": True})
            else:
                respond_error(rid, 404, f"unknown method: {method}")
        except Exception as exc:  # noqa: BLE001
            respond_error(rid, 500, f"{type(exc).__name__}: {exc}")

    def serve_stdin(self) -> None:
        for line in sys.stdin:
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
    _stderr(f"starting host={DEFAULT_HOST} port={RELAY_PORT}")
    runner = Runner()
    emit({"event": "ready"})
    try:
        runner.serve_stdin()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        runner.subscriber.stop()


if __name__ == "__main__":
    main()
