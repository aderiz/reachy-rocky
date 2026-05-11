"""MLX-Whisper STT sidecar entry point.

JSON-line wire protocol per the SidecarHost contract.

Methods:
  warm_up()              -> { "ms": float }
                             Force a model load (first call would otherwise
                             pay the cost on the first real transcribe).
  transcribe(params)     -> { "text", "duration_ms", "confidence", "sample_rate" }
                             params:
                               samples_b64: base64 of int16 LE mono PCM
                               sample_rate: int (must be 16000; resampling
                                            is the caller's responsibility)
                               language:   optional, defaults to ROCKY_STT_LANGUAGE
  health()               -> { "model", "loaded", "language" }

The model is loaded lazily on the first `warm_up` or `transcribe` so the
SidecarHost ready_event fires fast and the supervisor doesn't time out
on a slow first model fetch (~3 GB for whisper-large-v3-mlx).
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import traceback
from typing import Any

import numpy as np


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(level: str, msg: str, **fields: Any) -> None:
    emit({"log": {"level": level, "msg": msg, "fields": {k: str(v) for k, v in fields.items()}}})


def respond(req_id: str, result: Any) -> None:
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str) -> None:
    emit({"id": req_id, "error": {"code": code, "message": message}})


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[mlx-stt] {msg}\n")
    sys.stderr.flush()


class Runner:
    def __init__(self) -> None:
        self.model_id = (
            os.environ.get("ROCKY_STT_MODEL")
            or "mlx-community/whisper-large-v3-mlx"
        )
        self.language = os.environ.get("ROCKY_STT_LANGUAGE") or "en"
        self._loaded = False
        _stderr(f"runner constructed, model={self.model_id} lang={self.language}")

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        # Import is lazy because `mlx_whisper` pulls in mlx + a couple
        # hundred MB of supporting libs; we don't want to pay that
        # cost when the user opens the app with sttEngine = "apple".
        import mlx_whisper  # noqa: F401 — module presence implies install
        self._loaded = True
        _stderr(f"model loaded path={self.model_id}")

    # ------------------------------------------------------------------
    # Transcription
    # ------------------------------------------------------------------

    def transcribe(self, params: dict[str, Any]) -> dict[str, Any]:
        self._ensure_loaded()
        import mlx_whisper

        b64 = params.get("samples_b64")
        if not isinstance(b64, str):
            raise ValueError("samples_b64 must be a string")
        sample_rate = int(params.get("sample_rate") or 16_000)
        language = params.get("language") or self.language

        if sample_rate != 16_000:
            # mlx-whisper expects 16 kHz internally. We could resample
            # here but the Mac-side pipeline already normalises to
            # 16 kHz, so a mismatch is a real bug worth surfacing.
            raise ValueError(
                f"mlx-whisper expects 16 kHz; got {sample_rate} Hz"
            )

        pcm = base64.b64decode(b64)
        if not pcm:
            raise ValueError("empty samples_b64")

        # int16 LE → float32 mono in [-1, 1]
        i16 = np.frombuffer(pcm, dtype="<i2")
        audio = i16.astype(np.float32) / 32768.0

        t0 = time.perf_counter()
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model_id,
            language=language,
            # Greedy decode for lowest latency on short utterances.
            # The wake/conversation pipeline never deals with hours-
            # long audio segments — they're capped by VoiceCoordinator
            # at ~12 s — so beam search overhead isn't justified.
            temperature=0.0,
            verbose=False,
        )
        duration_ms = (time.perf_counter() - t0) * 1000

        text = (result.get("text") or "").strip()
        return {
            "text": text,
            "duration_ms": duration_ms,
            "confidence": 1.0,
            "sample_rate": sample_rate,
            "model": self.model_id,
            "language": result.get("language") or language,
        }

    def warm_up(self) -> dict[str, Any]:
        # Run a tiny synthetic transcribe so weights are fully loaded
        # AND the codec / tokenizer state is realised. Without this the
        # first real transcribe pays the entire ~5 s load cost.
        t0 = time.perf_counter()
        self._ensure_loaded()
        try:
            import mlx_whisper
            silence = np.zeros(16_000, dtype=np.float32)  # 1 s of silence
            mlx_whisper.transcribe(
                silence,
                path_or_hf_repo=self.model_id,
                language=self.language,
                temperature=0.0,
                verbose=False,
            )
        except Exception as exc:  # noqa: BLE001
            _stderr(f"warm_up transcribe failed (non-fatal): {exc}")
        return {"ms": (time.perf_counter() - t0) * 1000}

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    def handle(self, req: dict[str, Any]) -> None:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if rid is None or not method:
            return
        try:
            if method == "transcribe":
                respond(rid, self.transcribe(params))
            elif method == "warm_up":
                respond(rid, self.warm_up())
            elif method == "health":
                respond(rid, {
                    "model": self.model_id,
                    "loaded": self._loaded,
                    "language": self.language,
                })
            else:
                respond_error(rid, 404, f"unknown method: {method}")
        except Exception as exc:  # noqa: BLE001
            log("error", "handler crashed",
                error=str(exc), tb=traceback.format_exc())
            respond_error(rid, 500, f"{type(exc).__name__}: {exc}")


def main() -> None:
    _stderr("starting")
    runner = Runner()
    emit({"event": "ready"})
    _stderr("ready emitted")
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
