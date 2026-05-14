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


# Whisper's training corpus is heavy on YouTube subtitles, which end
# with credit / sign-off boilerplate. Fed silence or low-energy audio,
# the model loves to spit these out with confident-looking probs.
# We don't drop a phrase that simply *matches* the list (a real user
# can absolutely say "thank you") — we drop only when Whisper's own
# segment metadata flags low confidence too (see _is_hallucinated).
_HALLUCINATION_PHRASES: frozenset[str] = frozenset({
    "thank you",
    "thanks",
    "thanks for watching",
    "thanks for watching!",
    "thank you for watching",
    "thanks for watching everyone",
    "thanks for watching, see you next time",
    "please subscribe",
    "subscribe to my channel",
    "subtitles by the amara.org community",
    "transcription by espresso media",
    "bye",
    "goodbye",
    "i love you",
    "you",
    "thank",
    "okay",
    "thanks!",
    "see you next time",
    ".",
})


def _normalise_for_match(text: str) -> str:
    """Lower-case, strip punctuation, collapse whitespace — used to
    compare a transcript against the hallucination phrase set."""
    import re
    t = text.lower().strip()
    t = re.sub(r"[^\w\s]", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _is_hallucinated(result: dict) -> bool:
    """Heuristic: drop the transcript only when *both* hold:
      a) the normalised text matches a known Whisper hallucination
      b) the segment metadata says the model wasn't confident.

    Confidence gates:
      - `no_speech_prob >= 0.4` → model itself thinks the segment is
        probably silence; high values + a known-hallucination string
        are textbook silence-driven boilerplate output.
      - `avg_logprob <= -0.8` → the chosen tokens were low-likelihood
        even by greedy/sampled decoding. A real "thank you" said
        clearly into the mic logs around -0.2 to -0.4.

    Either gate alone is enough — we want to be permissive about
    real speech and aggressive about silence boilerplate.
    """
    text = (result.get("text") or "").strip()
    if not text:
        return False
    if _normalise_for_match(text) not in _HALLUCINATION_PHRASES:
        return False
    segments = result.get("segments") or []
    if not segments:
        # No segment metadata to consult — accept the transcript.
        return False
    # Pick the worst (most suspicious) segment in the response and
    # gate on that. Hallucinations on short utterances usually have
    # exactly one segment, so this is equivalent to the obvious
    # per-segment check; on multi-segment outputs we'd rather not
    # drop a real "thanks" mid-sentence.
    worst_no_speech = max(
        (float(seg.get("no_speech_prob") or 0.0) for seg in segments),
        default=0.0,
    )
    worst_avg_logprob = min(
        (float(seg.get("avg_logprob") or 0.0) for seg in segments),
        default=0.0,
    )
    suspicious = (worst_no_speech >= 0.4) or (worst_avg_logprob <= -0.8)
    if suspicious:
        _stderr(
            f"dropping hallucination: text={text!r} "
            f"no_speech={worst_no_speech:.3f} avg_lp={worst_avg_logprob:.3f}"
        )
    return suspicious


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
        # Default model: small-v3 (~244M, ~470 MB on disk). 2–3×
        # faster than medium-v3-mlx (which was itself 2–3× faster
        # than large-v3-mlx). On close-mic conversational English
        # the word-error-rate delta vs medium is ≤2%, and the
        # AddressFilter + hallucination gate already cushion the
        # marginal accuracy loss. The latency savings (typically
        # ~250–400 ms per turn) materially change the bot's
        # responsiveness. Override via ROCKY_STT_MODEL env var if
        # you want the bigger model.
        self.model_id = (
            os.environ.get("ROCKY_STT_MODEL")
            or "mlx-community/whisper-small-mlx"
        )
        self.language = os.environ.get("ROCKY_STT_LANGUAGE") or "en"
        self._loaded = False
        # Cached warmup metrics for the Mac's pull-based health
        # snapshot — mirrors the brain runner's `last_*` fields so
        # the Mac's Health view can render real timings via the
        # `health` RPC (the push-based log channel races vs.
        # subscriber setup during cold startup).
        self.last_load_time_ms: int | None = None
        self.last_warmup_ms: int | None = None
        self.last_warmup_failed: str | None = None
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

        # Fast early-out for clearly-silent segments. The VoiceCoordinator
        # already runs an EnergyVAD before flushing, but its threshold is
        # tuned to capture quiet/distant speech, which lets borderline-
        # silent segments through to the sidecar — where mlx_whisper
        # would spend its full ~250–500 ms producing either "" or a
        # hallucination. A 50 ms peak-RMS check on the segment short-
        # circuits this for a tiny fraction of the cost.
        if audio.size > 0:
            window = 800  # 50 ms at 16 kHz
            if audio.size >= window:
                # Peak RMS over rolling 50 ms windows. Stride by window
                # for speed; precision is fine for the floor check.
                view = audio[: (audio.size // window) * window].reshape(-1, window)
                peak_rms = float(np.sqrt((view * view).mean(axis=1)).max())
            else:
                peak_rms = float(np.sqrt((audio * audio).mean()))
            if peak_rms < 0.004:
                _stderr(f"skipped silent segment (peak_rms={peak_rms:.4f})")
                return {
                    "text": "",
                    "duration_ms": 0.0,
                    "confidence": 0.0,
                    "sample_rate": sample_rate,
                    "model": self.model_id,
                    "language": language,
                    "dropped": "silent",
                }

        t0 = time.perf_counter()
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model_id,
            language=language,
            # Single temperature pass. The previous (0.0, 0.4) ladder
            # let noise-driven segments burn ~500–900 ms on a second
            # attempt that essentially never recovered a useful
            # transcript anyway — the failure modes (logprob/compression
            # trip on noise) point at "this isn't speech" not "try
            # again hotter". With the silence early-out above and the
            # downstream hallucination/repetition gates, a single
            # greedy pass is enough.
            temperature=(0.0,),
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
            # No `initial_prompt`. The previous version primed the
            # decoder with "A short conversation between a person and
            # a robot named Rocky." — that worked AS DESIGNED
            # (steering away from "thanks for watching" YouTube
            # boilerplate) but had a worse side-effect: on silent or
            # noisy segments Whisper free-associates around the seed
            # tokens in the prompt and emits text like
            #   "The robot is now in the process of learning how to
            #    operate the robot. Thank you."
            # i.e. plausible robot-themed sentences that pass every
            # downstream gate because they don't look like junk. The
            # only safe seed is no seed. Generic YouTube-end
            # hallucinations are caught downstream by
            # `_is_hallucinated` + the AddressFilter's junk-phrase
            # deny-list; the robot-themed ones had no defence.
            verbose=False,
        )
        duration_ms = (time.perf_counter() - t0) * 1000

        # Confidence-gated drop for known silence hallucinations
        # ("thank you", "thanks for watching", etc.). We check the
        # whole `result` (text + segment metadata) and return empty
        # only when the model's own confidence flags the segment as
        # probably-silence. A real "thank you" said clearly passes
        # through.
        if _is_hallucinated(result):
            return {
                "text": "",
                "duration_ms": duration_ms,
                "confidence": 0.0,
                "sample_rate": sample_rate,
                "model": self.model_id,
                "language": result.get("language") or language,
                "dropped": "hallucination",
            }

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
        log(
            "info", "loading model",
            phase="load_start", model=self.model_id,
        )
        t0 = time.perf_counter()
        self._ensure_loaded()
        load_ms = int((time.perf_counter() - t0) * 1000)
        self.last_load_time_ms = load_ms
        log(
            "info", "stt model loaded",
            phase="load_done", model=self.model_id,
            load_time_ms=load_ms,
        )
        warm_started = time.perf_counter()
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
            warm_ms = int((time.perf_counter() - warm_started) * 1000)
            self.last_warmup_ms = warm_ms
            self.last_warmup_failed = None
            log(
                "info", "stt model warmed",
                phase="warm_done", model=self.model_id,
                warmup_ms=warm_ms,
            )
        except Exception as exc:  # noqa: BLE001
            self.last_warmup_failed = str(exc)
            _stderr(f"warm_up transcribe failed (non-fatal): {exc}")
            log(
                "warn", f"stt warm_up failed: {exc}",
                phase="warm_failed", model=self.model_id,
            )
        return {"ms": (time.perf_counter() - t0) * 1000}

    def health(self) -> dict[str, Any]:
        return {
            "model": self.model_id,
            "loaded": self._loaded,
            "language": self.language,
            "load_time_ms": self.last_load_time_ms,
            "warmup_ms": self.last_warmup_ms,
            "warmup_failed": self.last_warmup_failed,
            "warm": (
                self._loaded
                and self.last_warmup_ms is not None
                and self.last_warmup_failed is None
            ),
        }

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
                respond(rid, self.health())
            else:
                respond_error(rid, 404, f"unknown method: {method}")
        except Exception as exc:  # noqa: BLE001
            log("error", "handler crashed",
                error=str(exc), tb=traceback.format_exc())
            respond_error(rid, 500, f"{type(exc).__name__}: {exc}")


def main() -> None:
    _stderr("starting")
    runner = Runner()
    # Warm up BEFORE emitting `ready`, mirroring the brain sidecar
    # contract: when the Mac sees "ready" the model is genuinely
    # hot, not just instantiated. Without this, the user's first
    # transcribe (typically their first wake word) pays the full
    # ~3–5 s load+JIT cost on top of speech latency.
    try:
        runner.warm_up()
    except Exception as exc:  # noqa: BLE001
        _stderr(f"warm_up at boot failed (non-fatal): {exc}")
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
