"""Rocky Media Relay — on-bot Reachy Mini App.

Replaces the WebRTC remote-media path (which is unreliable on WiFi)
with a plain-WebSocket fan-out served from the daemon's app subprocess.

Audio + video are captured *locally* on the bot (via `media_backend="local"`
auto-selected by the SDK when running in-daemon), then pushed over
WebSocket to any number of remote subscribers — Rocky on the Mac in
the canonical case.

Endpoints (mounted under `self.settings_app`, which the daemon exposes
at the app's `custom_app_url`, default `http://0.0.0.0:8042`):

  GET  /health              — JSON liveness + counters (includes battery)
  GET  /battery             — battery snapshot. Combines sysfs (always
                              empty on the Wireless image — no BMS
                              kernel driver) with the *real* signal:
                              the Dynamixel motor supply voltage from
                              register 144, read through the daemon's
                              `WS /api/move/ws/raw/write`. Returns
                              power_source ("dc" / "battery"), voltage,
                              and a coarse LiFePO4 percent estimate.
  POST /control/start_recording   — begin audio capture (idempotent)
  POST /control/stop_recording    — stop audio capture (idempotent)
  WebSocket /ws/audio       — base64-encoded int16-LE mono PCM at 16 kHz +
                              periodic DoA frames + RMS
  WebSocket /ws/video       — base64-encoded JPEG frames, rate-limited
                              to ~15 fps to keep WS bandwidth reasonable

Wire format (each WS message is one JSON line):

  audio       {"type":"audio","ts_ms":int,"sr":16000,"ch":1,
               "rms":float,"pcm_b64":"..."}
  doa         {"type":"doa","ts_ms":int,"angle_rad":float,
               "is_speech":bool}
  video       {"type":"frame","ts_ms":int,"w":int,"h":int,
               "jpeg_b64":"..."}
  hello       {"type":"hello","sr":16000,"ch":1,"video_fps_cap":15,
               "build":"rocky-media-relay/0.1"}      (server → client on connect)

The single producer is the main `run()` loop. It polls
`mini.media.get_audio_sample()` / `get_frame()` / `get_DoA()` and pushes
serialised messages onto a per-client `asyncio.Queue`. Each connected
WebSocket has its own queue so a slow client backpressures only itself.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import threading
import time
from collections import deque
from typing import Optional

import numpy as np
from fastapi import WebSocket, WebSocketDisconnect
from reachy_mini import ReachyMini, ReachyMiniApp


logger = logging.getLogger("rocky-media-relay")
logger.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


VIDEO_FPS_CAP = 15  # ceiling for video forwarding; lower than the bot's
                    # native rate to keep WS bandwidth + Mac CPU sane.
VIDEO_JPEG_QUALITY = 70
VIDEO_TARGET_WIDTH = 480  # downscale; Rocky's face tracker + brain VLM both
                          # work fine on 480 px input.
DOA_MIN_INTERVAL_S = 0.2
AUDIO_SLEEP_S = 0.005  # tight loop; ReSpeaker delivers ~20 ms chunks.


# ---------------------------------------------------------------------------
# Per-client outbound queue
# ---------------------------------------------------------------------------


class ClientChannel:
    """One queue per WS client. Bounded so a stalled client gets dropped
    rather than ballooning memory. The producer drops oldest on overflow
    — newest audio / video matters more than buffered history."""

    MAX_PENDING = 200  # ~4 s at 50 Hz audio; >10 s at 15 fps video.

    def __init__(self) -> None:
        self.queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=self.MAX_PENDING)
        self.dropped = 0
        self.sent = 0

    def offer(self, msg: bytes) -> None:
        # Called from the producer thread via loop.call_soon_threadsafe.
        if self.queue.full():
            try:
                _ = self.queue.get_nowait()
                self.dropped += 1
            except asyncio.QueueEmpty:
                pass
        try:
            self.queue.put_nowait(msg)
        except asyncio.QueueFull:
            self.dropped += 1


# ---------------------------------------------------------------------------
# Producer state — single instance shared across WS clients
# ---------------------------------------------------------------------------


class RelayState:
    def __init__(self) -> None:
        self.audio_clients: set[ClientChannel] = set()
        self.video_clients: set[ClientChannel] = set()
        self.lock = threading.Lock()
        self.recording = True  # default-on so a fresh connect starts hot
        self.audio_emitted = 0
        self.video_emitted = 0
        self.doa_emitted = 0
        self.audio_dropped_total = 0
        self.video_dropped_total = 0
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        # Track first-frame logging per producer cycle.
        self.logged_first_audio = False
        self.logged_first_video = False

    def add_audio(self, ch: ClientChannel) -> None:
        with self.lock:
            self.audio_clients.add(ch)

    def remove_audio(self, ch: ClientChannel) -> None:
        with self.lock:
            self.audio_clients.discard(ch)

    def add_video(self, ch: ClientChannel) -> None:
        with self.lock:
            self.video_clients.add(ch)

    def remove_video(self, ch: ClientChannel) -> None:
        with self.lock:
            self.video_clients.discard(ch)

    def broadcast_audio(self, msg_bytes: bytes) -> None:
        # Producer runs on a worker thread; clients live on the asyncio
        # loop. call_soon_threadsafe nudges each queue from the
        # producer side without crossing event-loop boundaries.
        with self.lock:
            targets = list(self.audio_clients)
        loop = self.loop
        if loop is None:
            return
        for ch in targets:
            loop.call_soon_threadsafe(ch.offer, msg_bytes)

    def broadcast_video(self, msg_bytes: bytes) -> None:
        with self.lock:
            targets = list(self.video_clients)
        loop = self.loop
        if loop is None:
            return
        for ch in targets:
            loop.call_soon_threadsafe(ch.offer, msg_bytes)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_ms() -> int:
    return int(time.time() * 1000)


def _audio_msg(samples: np.ndarray, sr: int) -> bytes:
    """Convert ReSpeaker float32 stereo to int16 mono base64 + RMS,
    serialise to a JSON line. Downmix to mono because the brain /
    STT pipeline doesn't need spatial information at this layer."""
    if samples.ndim == 2 and samples.shape[1] >= 2:
        mono = samples.mean(axis=1)
    else:
        mono = samples.reshape(-1)
    clipped = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    pcm = clipped.tobytes()
    rms = float(np.sqrt(np.mean(mono * mono))) if mono.size else 0.0
    payload = {
        "type": "audio",
        "ts_ms": _now_ms(),
        "sr": int(sr),
        "ch": 1,
        "rms": rms,
        "pcm_b64": base64.b64encode(pcm).decode("ascii"),
    }
    return (json.dumps(payload) + "\n").encode("utf-8")


def _doa_msg(angle_rad: float, is_speech: bool) -> bytes:
    payload = {
        "type": "doa",
        "ts_ms": _now_ms(),
        "angle_rad": float(angle_rad),
        "is_speech": bool(is_speech),
    }
    return (json.dumps(payload) + "\n").encode("utf-8")


_PSU_BASE = "/sys/class/power_supply"
_BATTERY_CACHE_TTL_S = 2.0
_battery_cache: tuple[float, dict] = (0.0, {})

# Motor IDs the Reachy Mini Wireless ships with (1 base + 6 stewart + 2
# antennas, all on a single Dynamixel TTL bus). We probe 10-18 because
# that's the live ID range as of daemon 1.7.x. If Pollen renumbers in a
# future build, expand the range.
_DXL_MOTOR_IDS = tuple(range(10, 19))
_DXL_VOLTAGE_REG = 144           # PRESENT_INPUT_VOLTAGE, 2 bytes (signed)
_DXL_RAW_WS_URL = "ws://localhost:8000/api/move/ws/raw/write"
_VOLTAGE_CACHE_TTL_S = 5.0
_voltage_cache: dict = {"value": None, "fetched_at": 0.0, "samples": []}
# DC charger regulates to ~7.2 V; LiFePO4 2S sits at 6.4 V flat through
# most of discharge. A 6.9 V threshold cleanly separates them.
_DC_THRESHOLD_V = 6.9


def _dxl_crc16(data: bytes) -> int:
    """Robotis Dynamixel Protocol 2.0 CRC-16/BUYPASS.
    Polynomial 0x8005, initial 0x0000, no reflection."""
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x8005) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def _dxl_read_packet(mid: int, addr: int, n: int) -> bytes:
    """Construct a Dynamixel Protocol 2.0 READ packet."""
    body = bytes([
        0xFF, 0xFF, 0xFD, 0x00,
        mid,
        0x07, 0x00,
        0x02,
        addr & 0xFF, (addr >> 8) & 0xFF,
        n & 0xFF, (n >> 8) & 0xFF,
    ])
    crc = _dxl_crc16(body)
    return body + bytes([crc & 0xFF, (crc >> 8) & 0xFF])


def _parse_voltage_status(resp: bytes) -> Optional[float]:
    """Parse a Dynamixel status packet returning 2-byte voltage data
    (deci-volts → volts)."""
    if len(resp) < 11 or resp[7] != 0x55:
        return None
    import struct
    try:
        raw = struct.unpack("<h", resp[9:11])[0]
    except Exception:  # noqa: BLE001
        return None
    return raw / 10.0


async def _read_supply_voltage() -> Optional[tuple[float, list[float]]]:
    """Open the daemon's raw-packet WS, send READ packets to every
    motor, and return (median, [individual samples]).

    Returns None if no motor responds or the WS is unreachable.
    Cached `_VOLTAGE_CACHE_TTL_S` seconds to avoid hammering the daemon."""
    now = time.time()
    cached = _voltage_cache
    if cached["value"] is not None and (now - cached["fetched_at"]) < _VOLTAGE_CACHE_TTL_S:
        return cached["value"], list(cached["samples"])

    try:
        import websockets
    except ImportError:
        return None

    samples: list[float] = []
    try:
        async with websockets.connect(_DXL_RAW_WS_URL, open_timeout=1.0) as ws:
            for mid in _DXL_MOTOR_IDS:
                await ws.send(_dxl_read_packet(mid, _DXL_VOLTAGE_REG, 2))
                try:
                    resp = await asyncio.wait_for(ws.recv(), timeout=0.3)
                except asyncio.TimeoutError:
                    continue
                v = _parse_voltage_status(resp)
                if v is not None and 4.0 < v < 9.0:  # sanity range
                    samples.append(v)
    except Exception as exc:  # noqa: BLE001
        logger.debug("supply voltage read failed: %s", exc)
        return None

    if not samples:
        return None

    import statistics
    median_v = round(statistics.median(samples), 2)
    _voltage_cache["value"] = median_v
    _voltage_cache["samples"] = samples
    _voltage_cache["fetched_at"] = now
    return median_v, samples


def _estimate_lifepo4_percent(v: float) -> Optional[int]:
    """Map measured 2S-LiFePO4 pack voltage to a coarse state-of-charge
    percent. The discharge curve is very flat across the middle range
    (sits at ~6.4 V from ~80% down to ~20%), so this is necessarily a
    rough estimate — fine for a chip, useless for billing or rest-time
    projections.

    Anchors (measured / spec):
      7.00 V → 100%   (rested or charger-disconnected freshly full)
      6.70 V →  90%   (top of plateau)
      6.50 V →  60%   (mid plateau, observed when discharging)
      6.40 V →  35%   (bottom of plateau, BMS still happy)
      6.20 V →  15%   (knee of curve)
      6.00 V →   5%   (close to BMS cutoff)
      5.80 V →   0%   (BMS will trip very shortly)
    """
    if v >= 7.00:
        return 100
    if v >= 6.70:
        return int(round(90 + (v - 6.70) / 0.30 * 10))
    if v >= 6.50:
        return int(round(60 + (v - 6.50) / 0.20 * 30))
    if v >= 6.40:
        return int(round(35 + (v - 6.40) / 0.10 * 25))
    if v >= 6.20:
        return int(round(15 + (v - 6.20) / 0.20 * 20))
    if v >= 6.00:
        return int(round(5 + (v - 6.00) / 0.20 * 10))
    if v >= 5.80:
        return int(round((v - 5.80) / 0.20 * 5))
    return 0


def _psu_read_str(node: str, key: str) -> Optional[str]:
    try:
        with open(os.path.join(_PSU_BASE, node, key), "r") as f:
            return f.read().strip()
    except OSError:
        return None


def _psu_read_int(node: str, key: str) -> Optional[int]:
    s = _psu_read_str(node, key)
    if s is None:
        return None
    try:
        return int(s)
    except ValueError:
        return None


def _read_battery_uncached() -> dict:
    """Read battery state from /sys/class/power_supply/* on the CM4.

    Reachy Mini Wireless has a LiFePO4 pack + BMS. Whether the BMS is
    surfaced to the kernel depends on the bot's image — there's no
    daemon API for it (verified via /openapi.json and /api/state/full).
    This walks sysfs and reports whatever the kernel exposes. If no
    Battery node is present, returns present=False so callers know
    the bot can't tell them, rather than guessing from voltage.

    Result fields (any may be null if the kernel doesn't expose them):
      present       — whether a Battery PSU node was found
      percent       — 0–100, from `capacity`
      status        — Linux PSU status string ("Charging", "Discharging",
                       "Full", "Not charging", "Unknown")
      charging      — derived: status == "Charging"
      plugged_in    — true if any Mains/USB/ACAD PSU reports online=1,
                       or (when no AC node exists) derived from the
                       battery status. Reachy Mini's USB-C is DATA only
                       and doesn't charge, so this is informational
                       only on the stock image.
      voltage_v     — pack voltage, from `voltage_now` (µV → V)
      current_a     — pack current, from `current_now` (µA → A; sign
                       indicates direction per kernel convention)
      temperature_c — pack temperature, from `temp` (dC → C)
      source        — sysfs node name (e.g. "bq27441-0")
    Never raises.
    """
    result: dict = {
        "present": False,
        "percent": None,
        "status": None,
        "charging": None,
        "plugged_in": None,
        "voltage_v": None,
        "current_a": None,
        "temperature_c": None,
        "source": None,
    }
    try:
        entries = os.listdir(_PSU_BASE)
    except OSError:
        return result

    battery_node: Optional[str] = None
    have_ac = False
    online_any = False
    for name in sorted(entries):
        psu_type = _psu_read_str(name, "type")
        if psu_type == "Battery" and battery_node is None:
            battery_node = name
        elif psu_type in ("Mains", "USB", "USB_PD", "ACAD", "Wireless"):
            have_ac = True
            if _psu_read_int(name, "online") == 1:
                online_any = True

    if battery_node is None:
        result["plugged_in"] = online_any if have_ac else None
        return result

    result["present"] = True
    result["source"] = battery_node
    pct = _psu_read_int(battery_node, "capacity")
    if pct is not None:
        result["percent"] = max(0, min(100, pct))
    status = _psu_read_str(battery_node, "status")
    if status:
        result["status"] = status
        lc = status.lower()
        result["charging"] = (lc == "charging")
        if have_ac:
            result["plugged_in"] = online_any
        else:
            # No separate AC node — derive plugged_in from the
            # battery's own status. "Discharging" is the only state
            # where we're definitely on battery alone.
            result["plugged_in"] = lc in ("charging", "full", "not charging")
    voltage_uv = _psu_read_int(battery_node, "voltage_now")
    if voltage_uv is not None:
        result["voltage_v"] = round(voltage_uv / 1e6, 3)
    current_ua = _psu_read_int(battery_node, "current_now")
    if current_ua is not None:
        result["current_a"] = round(current_ua / 1e6, 3)
    temp_dc = _psu_read_int(battery_node, "temp")  # deci-Celsius
    if temp_dc is not None:
        result["temperature_c"] = round(temp_dc / 10.0, 1)
    return result


def read_battery() -> dict:
    """Cached wrapper around `_read_battery_uncached` — sysfs reads
    are cheap but we still don't want to hit them on every WS message."""
    global _battery_cache
    now = time.time()
    ts, snap = _battery_cache
    if snap and (now - ts) < _BATTERY_CACHE_TTL_S:
        return snap
    snap = _read_battery_uncached()
    _battery_cache = (now, snap)
    return snap


def _frame_msg(frame_bgr: np.ndarray) -> Optional[bytes]:
    """Downscale + JPEG-encode. Uses Pillow because mlx-audio /
    reachy_mini already pull it in; avoids forcing OpenCV onto the
    bot's app venv. Returns None on encode failure (caller skips)."""
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        logger.warning("Pillow not available; video relay disabled")
        return None
    h, w = frame_bgr.shape[:2]
    # ReachyMini's appsink delivers BGR — convert to RGB for PIL.
    rgb = frame_bgr[:, :, ::-1]
    img = Image.fromarray(rgb, mode="RGB")
    if w > VIDEO_TARGET_WIDTH:
        scale = VIDEO_TARGET_WIDTH / w
        new_w = VIDEO_TARGET_WIDTH
        new_h = int(round(h * scale))
        img = img.resize((new_w, new_h), Image.Resampling.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=VIDEO_JPEG_QUALITY, optimize=False)
    jpeg = buf.getvalue()
    payload = {
        "type": "frame",
        "ts_ms": _now_ms(),
        "w": img.size[0],
        "h": img.size[1],
        "jpeg_b64": base64.b64encode(jpeg).decode("ascii"),
    }
    return (json.dumps(payload) + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------


class RockyMediaRelay(ReachyMiniApp):
    # Settings page lives at this URL. The daemon mounts our FastAPI
    # app under this prefix; we add WebSocket + control endpoints
    # there too. Binding to 0.0.0.0 is intentional — Rocky on the
    # Mac connects from outside.
    custom_app_url: str | None = "http://0.0.0.0:8042"
    # None == let the SDK auto-detect. In-daemon that resolves to
    # the LOCAL backend (IPC video + direct GStreamer audio) — no
    # WebRTC, no DTLS, no signalling churn.
    request_media_backend: str | None = None

    def run(self, reachy_mini: ReachyMini, stop_event: threading.Event):
        state = RelayState()

        # FastAPI control + websocket endpoints. Registered inside
        # run() per the SDK convention (settings_app routes added
        # here are picked up when the daemon serves the app).
        async def battery_snapshot() -> dict:
            """Fuse sysfs (always empty on Reachy Mini Wireless — no
            BMS driver in the stock image) with the actual signal:
            supply voltage read from the Dynamixel motors via the
            daemon's raw-packet WS. The motors continuously sample
            their power input and expose it on register 144.

            On DC the rail sits at ~7.2 V (charger regulation); on
            battery at 6.4–6.7 V (LiFePO4 2S). A 6.9 V threshold
            cleanly separates them.
            """
            snap = read_battery()  # sysfs base — `present` may be false
            v_result = await _read_supply_voltage()
            if v_result is None:
                return snap
            v_med, samples = v_result
            snap["present"] = True
            snap["voltage_v"] = v_med
            snap["source"] = "dynamixel:reg144"
            snap["motor_samples_v"] = samples
            # Estimate percent in both states. On DC the rail is the
            # charger's regulated voltage (~7.3 V) which maps to 100%
            # in the LiFePO4 curve; that matches iPhone-style "100% +
            # charging bolt" semantics once a battery has been on
            # charge for a while.
            snap["percent"] = _estimate_lifepo4_percent(v_med)
            if v_med > _DC_THRESHOLD_V:
                snap["power_source"] = "dc"
                snap["plugged_in"] = True
                snap["charging"] = True
                snap["status"] = "Charging"
            else:
                snap["power_source"] = "battery"
                snap["plugged_in"] = False
                snap["charging"] = False
                snap["status"] = "On battery"
            return snap

        @self.settings_app.get("/health")
        async def health():
            with state.lock:
                ac = len(state.audio_clients)
                vc = len(state.video_clients)
            return {
                "ok": True,
                "recording": state.recording,
                "audio_clients": ac,
                "video_clients": vc,
                "audio_emitted": state.audio_emitted,
                "video_emitted": state.video_emitted,
                "doa_emitted": state.doa_emitted,
                "audio_dropped_total": state.audio_dropped_total,
                "video_dropped_total": state.video_dropped_total,
                "video_fps_cap": VIDEO_FPS_CAP,
                "build": "rocky-media-relay/0.1",
                "battery": await battery_snapshot(),
            }

        @self.settings_app.get("/battery")
        async def battery():
            return await battery_snapshot()

        @self.settings_app.post("/control/start_recording")
        def start_recording():
            state.recording = True
            return {"recording": True}

        @self.settings_app.post("/control/stop_recording")
        def stop_recording():
            state.recording = False
            return {"recording": False}

        @self.settings_app.websocket("/ws/audio")
        async def audio_ws(ws: WebSocket):
            await ws.accept()
            # Remember the loop so the producer thread can dispatch
            # back into it via call_soon_threadsafe.
            state.loop = asyncio.get_running_loop()
            ch = ClientChannel()
            state.add_audio(ch)
            await ws.send_text(json.dumps({
                "type": "hello", "sr": 16000, "ch": 1,
                "video_fps_cap": VIDEO_FPS_CAP,
                "build": "rocky-media-relay/0.1",
            }))
            try:
                while True:
                    msg = await ch.queue.get()
                    await ws.send_bytes(msg)
                    ch.sent += 1
            except WebSocketDisconnect:
                pass
            except Exception as exc:  # noqa: BLE001
                logger.warning("audio ws error: %s", exc)
            finally:
                state.remove_audio(ch)

        @self.settings_app.websocket("/ws/video")
        async def video_ws(ws: WebSocket):
            await ws.accept()
            state.loop = asyncio.get_running_loop()
            ch = ClientChannel()
            state.add_video(ch)
            await ws.send_text(json.dumps({
                "type": "hello", "fps_cap": VIDEO_FPS_CAP,
                "jpeg_quality": VIDEO_JPEG_QUALITY,
                "build": "rocky-media-relay/0.1",
            }))
            try:
                while True:
                    msg = await ch.queue.get()
                    await ws.send_bytes(msg)
                    ch.sent += 1
            except WebSocketDisconnect:
                pass
            except Exception as exc:  # noqa: BLE001
                logger.warning("video ws error: %s", exc)
            finally:
                state.remove_video(ch)

        # Start recording on the daemon side so get_audio_sample()
        # returns real PCM. With media_backend=local this just nudges
        # GStreamer's audio source; it's idempotent.
        try:
            reachy_mini.media.start_recording()
        except Exception as exc:  # noqa: BLE001
            logger.warning("start_recording failed at startup: %s", exc)

        # Track first frame for diagnostics (mirrors the symptom-debug
        # additions we already have in Sidecars/robot-mic).
        state.logged_first_audio = False
        state.logged_first_video = False

        last_video_emit = 0.0
        last_doa_emit = 0.0
        last_health_log = time.time()

        sample_rate = 16_000
        try:
            sample_rate = int(reachy_mini.media.get_input_audio_samplerate() or 16_000)
        except Exception:
            pass

        logger.info("rocky-media-relay producer loop online (sr=%d)", sample_rate)

        while not stop_event.is_set():
            now = time.time()

            # ---- audio ----
            if state.recording:
                try:
                    samples = reachy_mini.media.get_audio_sample()
                except Exception as exc:  # noqa: BLE001
                    samples = None
                    logger.debug("get_audio_sample raised: %s", exc)
                if samples is not None and len(samples):
                    arr = np.asarray(samples, dtype=np.float32)
                    if not state.logged_first_audio:
                        state.logged_first_audio = True
                        peak = float(np.max(np.abs(arr))) if arr.size else 0.0
                        logger.info(
                            "first audio frame shape=%s dtype=%s peak=%.5f",
                            arr.shape, arr.dtype, peak,
                        )
                    msg = _audio_msg(arr, sample_rate)
                    state.broadcast_audio(msg)
                    state.audio_emitted += 1

                # ---- DoA (low-rate) ----
                if now - last_doa_emit >= DOA_MIN_INTERVAL_S:
                    try:
                        doa = reachy_mini.media.get_DoA()
                    except Exception:
                        doa = None
                    if doa is not None:
                        angle, is_speech = doa
                        state.broadcast_audio(_doa_msg(angle, is_speech))
                        state.doa_emitted += 1
                        last_doa_emit = now

            # ---- video (rate-limited) ----
            min_video_dt = 1.0 / VIDEO_FPS_CAP
            if (now - last_video_emit) >= min_video_dt:
                with state.lock:
                    have_video_clients = len(state.video_clients) > 0
                if have_video_clients:
                    try:
                        frame = reachy_mini.media.get_frame()
                    except Exception:
                        frame = None
                    if frame is not None:
                        if not state.logged_first_video:
                            state.logged_first_video = True
                            logger.info(
                                "first video frame shape=%s dtype=%s",
                                frame.shape, frame.dtype,
                            )
                        msg = _frame_msg(np.asarray(frame))
                        if msg is not None:
                            state.broadcast_video(msg)
                            state.video_emitted += 1
                            last_video_emit = now

            # ---- periodic health log ----
            if now - last_health_log >= 10.0:
                with state.lock:
                    ac = len(state.audio_clients)
                    vc = len(state.video_clients)
                logger.info(
                    "health: audio_clients=%d video_clients=%d "
                    "audio_emitted=%d video_emitted=%d doa=%d",
                    ac, vc,
                    state.audio_emitted, state.video_emitted, state.doa_emitted,
                )
                last_health_log = now

            time.sleep(AUDIO_SLEEP_S)

        # ---- shutdown ----
        try:
            reachy_mini.media.stop_recording()
        except Exception:
            pass
        logger.info("rocky-media-relay stopped cleanly")


if __name__ == "__main__":
    app = RockyMediaRelay()
    try:
        app.wrapped_run()
    except KeyboardInterrupt:
        app.stop()
