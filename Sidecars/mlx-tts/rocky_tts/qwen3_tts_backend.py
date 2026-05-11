"""Qwen3-TTS-12Hz Base backend (mlx-community / Qwen3 via mlx-audio).

Streaming: ~800 ms first-packet on this Mac via Qwen3-TTS-12Hz's
dual-track LM architecture — emits PCM chunks as the model generates,
so Rocky can start speaking before the full reply is synthesised.

Voice cloning: the **Base** variant supports in-context-learning (ICL)
voice cloning from a 3-second reference clip in
`~/Library/Application Support/Rocky/voice/reference.wav` plus the
verbatim transcript of that clip in `ROCKY_TTS_REF_TEXT`. When both
are present the model speaks in the cloned voice; otherwise it falls
back to the model's default synthesis (no cloning).

The sibling **CustomVoice** variant cannot clone — it uses a fixed
roster of pretrained speakers. Rocky targets cloning, so we use Base.

Defaults to `Qwen/Qwen3-TTS-12Hz-1.7B-Base`; override via
`ROCKY_TTS_QWEN3_MODEL`. Reference clip path override via
`ROCKY_TTS_REF_AUDIO`; transcript override via `ROCKY_TTS_REF_TEXT`.

Both `synthesize` (full WAV) and `synthesize_stream` (chunked PCM)
paths are exposed; the runner picks based on caller method.
"""

from __future__ import annotations

import io
import os
import struct
from pathlib import Path
from typing import Iterator

from .backends import Backend, SynthesisResult


DEFAULT_QWEN3_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"
DEFAULT_REF_NAME = "reference.wav"


class Qwen3TTSBackend(Backend):
    """Qwen3-TTS-12Hz with streaming-capable PCM emission. Chunks
    flow up to Swift's `StreamingTTS`, which routes them to the
    robot speaker via chunked upload + queued `play_sound` calls."""

    name = "qwen3-tts"
    supports_streaming = True

    def __init__(
        self,
        model_id: str | None = None,
        ref_audio_path: str | None = None,
        ref_text: str | None = None,
    ) -> None:
        self.model_id = (
            model_id
            or os.environ.get("ROCKY_TTS_QWEN3_MODEL")
            or DEFAULT_QWEN3_MODEL
        )
        self.ref_audio_path = ref_audio_path or self._resolve_ref_audio()
        # If ref_text wasn't passed explicitly or via env, try to load
        # it from the sidecar transcript file that lives next to the
        # reference clip (`sample.txt` / `reference.txt`).
        self.ref_text = (
            ref_text
            or os.environ.get("ROCKY_TTS_REF_TEXT")
            or self._resolve_ref_text()
        )
        self._loaded = False
        self._model = None
        self._processor = None

    # ------------------------------------------------------------------
    # Reference-audio + reference-text resolution
    # ------------------------------------------------------------------

    def _resolve_ref_audio(self) -> str | None:
        """Find a voice-reference WAV. Priority:
        1. `ROCKY_TTS_REF_AUDIO` env var (absolute path)
        2. `~/Library/Application Support/Rocky/voice/reference.wav`
        3. `~/Library/Application Support/Rocky/voice/sample.wav`
           (Rocky cockpit's onboarding writes here)
        """
        env = os.environ.get("ROCKY_TTS_REF_AUDIO")
        if env and Path(env).is_file():
            return env
        for name in (DEFAULT_REF_NAME, "sample.wav"):
            candidate = DEFAULT_REF_DIR / name
            if candidate.is_file():
                return str(candidate)
        return None

    def _resolve_ref_text(self) -> str | None:
        """Load the transcript paired with the reference clip, looking
        for `reference.txt` first, then `sample.txt`. Returns None
        when no transcript is available — the model then falls back to
        non-ICL synthesis."""
        # If ref_audio_path is set, prefer a sibling .txt with the
        # same stem (e.g. `sample.wav` → `sample.txt`).
        if self.ref_audio_path:
            sibling = Path(self.ref_audio_path).with_suffix(".txt")
            if sibling.is_file():
                try:
                    return sibling.read_text(encoding="utf-8").strip() or None
                except OSError:
                    pass
        for name in ("reference.txt", "sample.txt"):
            candidate = DEFAULT_REF_DIR / name
            if candidate.is_file():
                try:
                    return candidate.read_text(encoding="utf-8").strip() or None
                except OSError:
                    continue
        return None

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        """Persist a new voice reference under
        ~/Library/Application Support/Rocky/voice/<id>.wav and switch
        future synthesis to use it."""
        DEFAULT_REF_DIR.mkdir(parents=True, exist_ok=True)
        path = DEFAULT_REF_DIR / f"{voice_ref_id}.wav"
        path.write_bytes(wav_bytes)
        self.ref_audio_path = str(path)

    # ------------------------------------------------------------------
    # Model loading
    # ------------------------------------------------------------------

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        # Lazy import — mlx_audio is heavy. Done on first synth so
        # the supervisor's ready_event doesn't time out on a slow
        # disk.
        from mlx_audio.tts.utils import load_model  # type: ignore

        self._model = load_model(self.model_id)
        self._loaded = True

    # ------------------------------------------------------------------
    # Full-WAV synthesis (compat with the original Backend interface)
    # ------------------------------------------------------------------

    def synthesize(
        self,
        text: str,
        voice_ref_id: str | None,
    ) -> SynthesisResult:
        chunks: list[bytes] = []
        sample_rate = 16_000
        for pcm, sr in self.synthesize_stream(text, voice_ref_id):
            chunks.append(pcm)
            sample_rate = sr
        pcm_concat = b"".join(chunks)
        wav_bytes = _wrap_pcm_in_wav(pcm_concat, sample_rate=sample_rate)
        duration_s = len(pcm_concat) / (sample_rate * 2)  # int16 mono
        return SynthesisResult(
            wav_bytes=wav_bytes,
            sample_rate=sample_rate,
            channels=1,
            duration_s=duration_s,
        )

    def warm_up(self) -> None:
        try:
            self._ensure_loaded()
        except Exception:  # noqa: BLE001 — defer error to first synth
            pass

    # ------------------------------------------------------------------
    # Streaming synthesis — yields (pcm_bytes_int16, sample_rate)
    # ------------------------------------------------------------------

    def synthesize_stream(
        self,
        text: str,
        voice_ref_id: str | None,
    ) -> Iterator[tuple[bytes, int]]:
        self._ensure_loaded()

        # `Model.generate(...)` from qwen3_tts is the canonical
        # streaming generator — yields `GenerationResult` objects
        # with `.audio` (mx.array) and `.sample_rate`. We call it
        # directly instead of `mlx_audio.tts.generate.generate_audio`,
        # which consumes the iterator internally for playback /
        # save side-effects.
        #
        # Base model branches inside `generate`:
        #   - ref_audio AND ref_text supplied → ICL voice cloning
        #     (the Rocky path; uses the user's 3-second reference)
        #   - otherwise → standard synthesis with the model's
        #     default voice (no cloning; this is the first-run path
        #     before the user has recorded a reference)
        # `streaming_interval=0.32` (~4 codec tokens at 12.5 Hz) is the
        # canonical low-latency setting from the mlx-audio v0.4.3 Qwen3-
        # TTS README. Default is 2.0 s — too coarse for live-assistant
        # responsiveness. 0.32 s gets first chunk within a few hundred
        # ms after the ICL prefill (which is the floor we can't avoid).
        for result in self._model.generate(  # type: ignore[union-attr]
            text=text,
            ref_audio=self.ref_audio_path,
            ref_text=self.ref_text,
            stream=True,
            streaming_interval=0.32,
            verbose=False,
        ):
            audio = getattr(result, "audio", result)
            sr = int(getattr(result, "sample_rate", 16_000))
            yield _to_int16_bytes(audio), sr


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _to_int16_bytes(audio) -> bytes:
    """Convert an mlx / numpy float audio buffer to little-endian int16
    bytes, clipping to [-1.0, 1.0] to avoid wrap-around."""
    try:
        import numpy as np  # type: ignore
    except ImportError:
        # As a last resort emit a Python-side conversion.
        result = bytearray()
        for sample in audio:
            v = max(-1.0, min(1.0, float(sample)))
            result.extend(struct.pack("<h", int(v * 32767)))
        return bytes(result)
    arr = np.asarray(audio, dtype="float32")
    arr = np.clip(arr, -1.0, 1.0)
    return (arr * 32767).astype("<i2").tobytes()


def _wrap_pcm_in_wav(pcm: bytes, sample_rate: int = 16_000) -> bytes:
    """Wrap raw int16 mono PCM in a minimal WAV (RIFF) header so
    callers that expect WAV (legacy `synthesize` path) get one."""
    bits = 16
    channels = 1
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    data_size = len(pcm)
    riff_size = 36 + data_size
    header = bytearray()
    header += b"RIFF"
    header += struct.pack("<I", riff_size)
    header += b"WAVEfmt "
    header += struct.pack("<I", 16)        # fmt chunk size
    header += struct.pack("<H", 1)         # PCM
    header += struct.pack("<H", channels)
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", byte_rate)
    header += struct.pack("<H", block_align)
    header += struct.pack("<H", bits)
    header += b"data"
    header += struct.pack("<I", data_size)
    return bytes(header) + pcm
