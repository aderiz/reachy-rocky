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


_WORD_RE_PATTERN = r"\S+"


def _collapse_repetition(text: str, min_repeats: int = 3) -> str:
    """Detect and collapse runs of any repeating n-gram in the
    transcript. Whisper hallucinations come in three shapes:

      a) Sentence-level: "X. X. X. X. X."
      b) Phrase-level w/o punctuation: "I'm going to X I'm going to X..."
      c) Single-word loops: "yeah yeah yeah yeah yeah yeah"

    The previous sentence-split approach only caught (a). This walks
    the text token-by-token and, at each position, finds the LONGEST
    n-gram (n from a few words up to a sentence-ish length) that
    repeats consecutively `min_repeats` times. The longest match
    wins so we collapse the most aggressive run rather than a
    fragment of it.

    Leaves untouched any text where the same phrase doesn't appear
    consecutively at least `min_repeats` times — natural repetition
    in human speech ("yes yes" / "no no") is preserved.
    """
    import re
    if not text:
        return text
    tokens = re.findall(_WORD_RE_PATTERN, text)
    if len(tokens) < min_repeats * 2:
        return text

    # Normaliser used for matching only — output uses original casing.
    def norm(s: str) -> str:
        return re.sub(r"[^\w]", "", s).lower()
    norms = [norm(t) for t in tokens]

    n_tokens = len(tokens)
    keep = [True] * n_tokens
    # Try n-gram sizes from largest plausible (half the input)
    # down to single tokens. Largest-first means a 4-word loop
    # gets collapsed as a whole, not as a 1-word loop nested
    # inside it.
    max_n = max(1, n_tokens // min_repeats)
    i = 0
    collapsed_examples: list[str] = []
    while i < n_tokens:
        if not keep[i]:
            i += 1
            continue
        matched_n = 0
        matched_run = 0
        for n in range(min(max_n, n_tokens - i), 0, -1):
            if i + n * min_repeats > n_tokens:
                continue
            # Count consecutive identical n-grams starting at i.
            run = 1
            base = norms[i:i + n]
            # Skip if the n-gram contains only empty / pure-punctuation
            # tokens (post-normalisation), which can produce spurious
            # matches on filler.
            if not any(b for b in base):
                continue
            while True:
                j = i + run * n
                if j + n > n_tokens:
                    break
                if norms[j:j + n] != base:
                    break
                run += 1
            if run >= min_repeats and run * n > matched_run:
                matched_n = n
                matched_run = run * n
        if matched_n > 0:
            run_copies = matched_run // matched_n
            phrase = " ".join(tokens[i:i + matched_n])
            for k in range(matched_n, matched_run):
                keep[i + k] = False
            collapsed_examples.append(f"{run_copies}× {phrase!r}")
            i += matched_run
        else:
            i += 1

    if collapsed_examples:
        _stderr(f"collapsed repetition: {'; '.join(collapsed_examples)}")
    return " ".join(t for t, k in zip(tokens, keep) if k).strip()


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
            # Whisper-large-v3 is prone to repetition hallucinations
            # on short utterances. Use the official OpenAI ladder
            # so the model retries at higher temperatures when its
            # `compression_ratio_threshold` fires.
            temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
            # 2.4 is the upstream default but lets through "X. X. X."
            # 3-4 times before flagging. 1.8 catches milder cases
            # too — false-positive rate is low for natural speech.
            compression_ratio_threshold=1.8,
            # 0.7 is more aggressive than upstream's 0.6 — discards
            # segments Whisper considers low-confidence speech, which
            # is where hallucinated continuations live.
            no_speech_threshold=0.7,
            # Don't feed this turn's transcript back as context for
            # the next call — compounds repetition errors across
            # consecutive utterances in a conversation.
            condition_on_previous_text=False,
            verbose=False,
        )
        duration_ms = (time.perf_counter() - t0) * 1000

        text = (result.get("text") or "").strip()
        # Belt-and-braces: even with the upstream fallback, every
        # temperature sometimes produces the same repetitive trap
        # and the last attempt is returned. A sliding-window n-gram
        # filter catches all the common patterns — sentence repeats,
        # phrase repeats without punctuation, single-word stuck loops.
        text = _collapse_repetition(text)

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
