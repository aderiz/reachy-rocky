"""Qwen3-TTS-12Hz CustomVoice backend (mlx-community / Qwen3 via mlx-audio).

Streaming: 97 ms first-packet latency via Qwen3-TTS-12Hz's dual-track LM
architecture — emits PCM chunks as the model generates, so Rocky can
start speaking before the full reply is synthesised. Voice cloning
from a 3-second reference clip in
`~/Library/Application Support/Rocky/voice/`.

Defaults to `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice`; override via
`ROCKY_TTS_QWEN3_MODEL`.

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


DEFAULT_QWEN3_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"
DEFAULT_REF_NAME = "reference.wav"


class Qwen3TTSBackend(Backend):
    """Qwen3-TTS-12Hz with streaming-capable PCM emission."""

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
        self.ref_text = ref_text or os.environ.get("ROCKY_TTS_REF_TEXT") or None
        self._loaded = False
        self._model = None
        self._processor = None

    # ------------------------------------------------------------------
    # Reference-audio resolution
    # ------------------------------------------------------------------

    def _resolve_ref_audio(self) -> str | None:
        env = os.environ.get("ROCKY_TTS_REF_AUDIO")
        if env and Path(env).is_file():
            return env
        default = DEFAULT_REF_DIR / DEFAULT_REF_NAME
        return str(default) if default.is_file() else None

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

        # mlx-audio's generate API for Qwen3-TTS exposes a
        # generator-style `generate(text, ref_audio=..., ref_text=...,
        # stream=True)` that yields chunks. The exact entry point
        # varies between mlx-audio versions; try a few in priority
        # order and fall back to a single-shot generate that yields
        # the whole buffer at once.
        try:
            from mlx_audio.tts.models.qwen3_tts import generate as q_generate  # type: ignore
            for chunk in q_generate(
                model=self._model,
                text=text,
                ref_audio=self.ref_audio_path,
                ref_text=self.ref_text,
                stream=True,
            ):
                pcm = _to_int16_bytes(chunk.audio)
                sr = int(getattr(chunk, "sample_rate", 16_000))
                yield pcm, sr
            return
        except Exception:  # noqa: BLE001 — fall through to non-streaming
            pass

        # Non-streaming fallback — yields the full buffer in one
        # chunk. Same on-the-wire shape; downstream players treat it
        # as a single 'pcm_chunk' event followed by 'synth_end'.
        from mlx_audio.tts.utils import generate_audio  # type: ignore
        result = generate_audio(
            model=self._model,
            text=text,
            ref_audio=self.ref_audio_path,
            ref_text=self.ref_text,
        )
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
