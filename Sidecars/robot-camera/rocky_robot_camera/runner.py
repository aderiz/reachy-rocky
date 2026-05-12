"""Robot-camera sidecar entry point (v0.2 — WebSocket subscriber).

Connects to the on-bot `rocky_media_relay` Reachy Mini App over a
plain WebSocket at `/ws/video` and republishes camera frames to the
Swift side using the existing `frame` event envelope. The Swift
adapter (`RobotCameraService`) sees no protocol change.

Stdin RPCs:
  start_streaming → resume the WebSocket subscription (idempotent;
                    re-opens /ws/video if `stop_streaming` previously
                    closed it). On the bot relay, video JPEG encoding
                    is gated on the count of /ws/video clients, so
                    closing this client makes the bot stop encoding.
  stop_streaming  → pause: close the active WS and stop reconnecting.
                    Frames stop flowing both on the wire and on the
                    bot CPU. Used so the camera feed sleeps with the
                    robot.
  health          → connection + counters.
  shutdown        → graceful exit.

Stdout events:
  ready  — once the WS supervisor is alive.
  frame  — { jpeg_b64, width, height, seq,
             source_width, source_height }
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
from typing import Any
from urllib.parse import urljoin
from urllib.request import Request, urlopen


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
    sys.stderr.write(f"[robot-camera] {msg}\n")
    sys.stderr.flush()


DEFAULT_HOST = os.environ.get("ROCKY_ROBOT_HOST", "reachy-mini.local")
RELAY_PORT = int(os.environ.get("ROCKY_RELAY_PORT", "8042"))
HTTP_BASE = f"http://{DEFAULT_HOST}:{RELAY_PORT}"
WS_URL = f"ws://{DEFAULT_HOST}:{RELAY_PORT}/ws/video"


class RelaySubscriber:
    """WS subscriber on its own asyncio thread. Reconnects with
    exponential-ish backoff. Translates the bot's `frame` envelope
    into the Swift-expected shape (adds a monotonic `seq` plus
    `source_*` so the Vision card can show original-resolution
    metadata even though the relay downscaled to ~480 wide)."""

    RECONNECT_BACKOFF_S = (1.0, 2.0, 5.0, 10.0)

    def __init__(self) -> None:
        self.shutdown = threading.Event()
        self.connected = threading.Event()
        self.paused = threading.Event()
        self.frames_received = 0
        self.last_w = 0
        self.last_h = 0
        self._loop: asyncio.AbstractEventLoop | None = None
        self._seq = 0
        self._thread = threading.Thread(
            target=self._thread_entry, name="ws-subscriber", daemon=True
        )
        self._logged_first_frame = False
        self._active_ws: Any | None = None
        self._resume_signal: asyncio.Event | None = None

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self.shutdown.set()
        loop = self._loop
        if loop is not None:
            # Wake any waiter on the resume signal so _supervise can exit.
            loop.call_soon_threadsafe(self._signal_resume_from_loop)
            self._close_active_ws_from_outside()
            loop.call_soon_threadsafe(loop.stop)

    def pause(self) -> None:
        """Stop streaming: set the paused flag and close the active WS.
        The supervisor will see `paused` set on its next iteration and
        wait on `_resume_signal` instead of reconnecting."""
        if self.paused.is_set():
            return
        _stderr("pause requested")
        self.paused.set()
        self._close_active_ws_from_outside()

    def resume(self) -> None:
        """Resume streaming: clear the paused flag and wake the
        supervisor so it reconnects."""
        if not self.paused.is_set():
            return
        _stderr("resume requested")
        self.paused.clear()
        loop = self._loop
        if loop is not None:
            loop.call_soon_threadsafe(self._signal_resume_from_loop)

    def _signal_resume_from_loop(self) -> None:
        if self._resume_signal is not None:
            self._resume_signal.set()

    def _close_active_ws_from_outside(self) -> None:
        loop = self._loop
        ws = self._active_ws
        if loop is None or ws is None:
            return
        async def _close():
            try:
                await ws.close()
            except Exception:  # noqa: BLE001
                pass
        try:
            asyncio.run_coroutine_threadsafe(_close(), loop)
        except Exception:  # noqa: BLE001
            pass

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
        self._resume_signal = asyncio.Event()
        attempt = 0
        while not self.shutdown.is_set():
            if self.paused.is_set():
                # Don't burn cycles or reconnect while paused.
                self._resume_signal.clear()
                _stderr("paused; waiting for resume")
                await self._resume_signal.wait()
                if self.shutdown.is_set():
                    return
                attempt = 0
                continue
            try:
                await self._connect_once()
                attempt = 0
            except asyncio.CancelledError:
                break
            except Exception as exc:  # noqa: BLE001
                if self.paused.is_set():
                    # The exception is our own close() — go round the
                    # loop and wait for resume; don't backoff-log.
                    continue
                wait = self.RECONNECT_BACKOFF_S[min(
                    attempt, len(self.RECONNECT_BACKOFF_S) - 1
                )]
                _stderr(f"ws disconnected ({type(exc).__name__}: {exc}); "
                        f"reconnect in {wait}s")
                self.connected.clear()
                attempt += 1
                for _ in range(int(wait * 10)):
                    if self.shutdown.is_set() or self.paused.is_set():
                        break
                    await asyncio.sleep(0.1)

    async def _connect_once(self) -> None:
        import websockets

        _stderr(f"connecting to {WS_URL}")
        async with websockets.connect(
            WS_URL,
            ping_interval=10,
            ping_timeout=20,
            max_size=None,
            close_timeout=5,
        ) as ws:
            self._active_ws = ws
            self.connected.set()
            _stderr(f"ws connected to {WS_URL}")
            try:
                async for raw in ws:
                    self._handle_message(raw)
            finally:
                self.connected.clear()
                self._active_ws = None

    def _handle_message(self, raw) -> None:
        if isinstance(raw, (bytes, bytearray)):
            try:
                text = raw.decode("utf-8").rstrip("\n")
            except UnicodeDecodeError:
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
        if t == "frame":
            self._handle_frame(obj)
        elif t == "hello":
            _stderr(f"hello: build={obj.get('build')} "
                    f"fps_cap={obj.get('fps_cap')}")

    def _handle_frame(self, obj: dict[str, Any]) -> None:
        jpeg_b64 = obj.get("jpeg_b64")
        w = obj.get("w") or obj.get("width")
        h = obj.get("h") or obj.get("height")
        if not isinstance(jpeg_b64, str) or w is None or h is None:
            return
        self._seq += 1
        # The bot relay already downscales to ~480 wide. The Vision
        # card's "source resolution" badge expects an upstream native
        # size; we don't have access to the raw sensor size here so
        # we report the relay-output size as source too. The brain's
        # VLM works on the delivered dimensions; only the badge text
        # is affected.
        emit({
            "event": "frame",
            "payload": {
                "jpeg_b64": jpeg_b64,
                "width": int(w),
                "height": int(h),
                "seq": self._seq,
                "source_width": int(w),
                "source_height": int(h),
            },
        })
        self.frames_received += 1
        self.last_w = int(w)
        self.last_h = int(h)
        if not self._logged_first_frame:
            self._logged_first_frame = True
            _stderr(f"first frame {w}x{h} (jpeg ~{len(jpeg_b64) * 3 // 4} bytes)")


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


class Runner:
    def __init__(self) -> None:
        self.subscriber = RelaySubscriber()
        self.subscriber.start()
        self.subscriber.connected.wait(timeout=2.0)
        self.streaming = False
        log("info", "robot-camera starting (ws relay)",
            host=DEFAULT_HOST, port=str(RELAY_PORT))

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        if rid is None or not method:
            return
        try:
            if method == "start_streaming":
                # Resume the WS subscription. The bot relay only
                # encodes JPEGs while it has at least one /ws/video
                # client, so reconnecting here also restarts encoding
                # on the bot side.
                self.subscriber.resume()
                self.streaming = True
                respond(rid, {"streaming": True})
            elif method == "stop_streaming":
                # Close the WS so the bot relay stops encoding video
                # (camera feed sleeps with the robot).
                self.subscriber.pause()
                self.streaming = False
                respond(rid, {"streaming": False})
            elif method == "health":
                respond(rid, {
                    "connected": self.subscriber.connected.is_set(),
                    "streaming": self.streaming,
                    "frames_received": self.subscriber.frames_received,
                    "last_w": self.subscriber.last_w,
                    "last_h": self.subscriber.last_h,
                    "host": DEFAULT_HOST,
                    "port": RELAY_PORT,
                    "transport": "websocket",
                })
            elif method == "shutdown":
                self.subscriber.stop()
                self.streaming = False
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
