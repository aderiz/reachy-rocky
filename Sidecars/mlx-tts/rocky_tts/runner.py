"""TTS sidecar entry point. JSON-line wire protocol per the SidecarHost contract."""

from __future__ import annotations

import base64
import json
import sys
import time
import traceback
from typing import Any

from .backends import make_backend


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(level: str, msg: str, **fields: Any) -> None:
    emit({"log": {"level": level, "msg": msg, "fields": {k: str(v) for k, v in fields.items()}}})


def respond(req_id: str, result: Any) -> None:
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str) -> None:
    emit({"id": req_id, "error": {"code": code, "message": message}})


class Runner:
    def __init__(self) -> None:
        self.backend = make_backend()
        self.voice_ref_id: str | None = None
        # Cached warmup metrics for the Mac's pull-based health
        # snapshot (mirrors brain + STT runners).
        self.last_warmup_ms: int | None = None
        self.last_warmup_failed: str | None = None
        log("info", "tts backend ready", backend=self.backend.name)

    def warm_up_at_boot(self) -> None:
        """Wrapper called from main() that times the backend warmup
        and caches the result for `health` to surface. Backend-level
        `warm_up()` itself is too varied (some load weights, some
        prime caches, some are no-ops) to time uniformly elsewhere."""
        t0 = time.monotonic()
        try:
            self.backend.warm_up()
            self.last_warmup_ms = int((time.monotonic() - t0) * 1000)
            self.last_warmup_failed = None
            log("info", "tts backend warmed",
                phase="warm_done", backend=self.backend.name,
                warmup_ms=self.last_warmup_ms)
        except Exception as exc:  # noqa: BLE001
            self.last_warmup_failed = str(exc)
            log("warn", f"tts warm_up failed: {exc}",
                phase="warm_failed", backend=self.backend.name)

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if rid is None or not method:
            return

        try:
            if method == "synthesize":
                text = str(params.get("text", "")).strip()
                voice_ref_id = params.get("voice_ref_id") or self.voice_ref_id
                if not text:
                    respond_error(rid, 400, "empty text")
                    return
                t0 = time.monotonic()
                result = self.backend.synthesize(text, voice_ref_id)
                synth_ms = (time.monotonic() - t0) * 1000
                respond(rid, {
                    "wav_b64": base64.b64encode(result.wav_bytes).decode("ascii"),
                    "sample_rate": result.sample_rate,
                    "channels": result.channels,
                    "duration_s": result.duration_s,
                    "synth_ms": synth_ms,
                    "backend": self.backend.name,
                })
            elif method == "synthesize_stream":
                text = str(params.get("text", "")).strip()
                voice_ref_id = params.get("voice_ref_id") or self.voice_ref_id
                if not text:
                    respond_error(rid, 400, "empty text")
                    return
                if not getattr(self.backend, "supports_streaming", False):
                    respond_error(
                        rid, 501,
                        f"backend {self.backend.name!r} doesn't support streaming",
                    )
                    return
                t0 = time.monotonic()
                first_chunk_ms = None
                total_pcm_bytes = 0
                sample_rate = 16_000
                index = 0
                for pcm, sr in self.backend.synthesize_stream(text, voice_ref_id):
                    if first_chunk_ms is None:
                        first_chunk_ms = (time.monotonic() - t0) * 1000
                    sample_rate = sr
                    total_pcm_bytes += len(pcm)
                    emit({
                        "id": rid,
                        "stream": {
                            "chunk_index": index,
                            "pcm_b64": base64.b64encode(pcm).decode("ascii"),
                            "sample_rate": sr,
                            "channels": 1,
                            "format": "s16le",
                        },
                    })
                    index += 1
                emit({"id": rid, "stream_end": True})
                duration_s = total_pcm_bytes / (sample_rate * 2)  # int16 mono
                respond(rid, {
                    "chunk_count": index,
                    "first_chunk_ms": first_chunk_ms,
                    "total_synth_ms": (time.monotonic() - t0) * 1000,
                    "sample_rate": sample_rate,
                    "channels": 1,
                    "format": "s16le",
                    "duration_s": duration_s,
                    "backend": self.backend.name,
                })
            elif method == "set_voice_ref":
                name = str(params.get("name", ""))
                wav_b64 = str(params.get("wav_b64", ""))
                if not name or not wav_b64:
                    respond_error(rid, 400, "name and wav_b64 required")
                    return
                wav = base64.b64decode(wav_b64)
                self.backend.set_voice_ref(name, wav)
                self.voice_ref_id = name
                respond(rid, {"ok": True, "voice_ref_id": name})
            elif method == "health":
                respond(rid, {
                    "backend": self.backend.name,
                    "voice_ref_id": self.voice_ref_id,
                    "streams": bool(getattr(self.backend, "supports_streaming", False)),
                    "warmup_ms": self.last_warmup_ms,
                    "warmup_failed": self.last_warmup_failed,
                    "warm": (
                        self.last_warmup_ms is not None
                        and self.last_warmup_failed is None
                    ),
                })
            elif method == "warm_up":
                t0 = time.monotonic()
                self.backend.warm_up()
                respond(rid, {"ok": True, "ms": (time.monotonic() - t0) * 1000})
            else:
                respond_error(rid, 404, f"unknown method: {method}")
        except Exception as exc:  # noqa: BLE001
            log("error", "handler crashed",
                error=str(exc), tb=traceback.format_exc())
            respond_error(rid, 500, f"{type(exc).__name__}: {exc}")


def main() -> None:
    runner = Runner()
    # Warm up BEFORE emitting `ready`. Same contract as the brain
    # and STT sidecars: when the Mac sees `ready` the TTS engine
    # is hot. First synthesis after wake otherwise pays the full
    # ~5–10 s model-load cost on top of the user's response
    # latency — felt as a long silence before Rocky finally talks.
    runner.warm_up_at_boot()
    emit({"event": "ready"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            log("error", "bad json", error=str(exc), line=line[:200])
            continue
        runner.handle(req)


if __name__ == "__main__":
    main()
