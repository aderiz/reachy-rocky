"""Fish Audio S2 Pro backend (`mlx-community/fish-audio-s2-pro-bf16`).

A second voice-cloning option alongside Qwen3-TTS Base. Loaded via
mlx-audio's `fish_qwen3_omni` model module — the HF config's
`model_type` field dispatches the registry. Voice cloning uses the
same `ref_audio` + `ref_text` pair Rocky already maintains in
`~/Library/Application Support/Rocky/voice/`.

Streaming: NOT supported. `Model.generate(stream=True)` raises
`NotImplementedError` in mlx-audio 0.4.3. The backend reports
`supports_streaming = False` so AppServices uses the legacy
`RobotTTS.speak` path (full WAV → upload → daemon `play_sound`),
which still routes only through the robot speaker.

Voice cloning needs both `ref_audio` (path to a 3–10 s WAV) and
`ref_text` (verbatim transcript). Without either, Fish falls back to
a generic voice — usable but not Rocky.

Defaults to `mlx-community/fish-audio-s2-pro-bf16`; override via
`ROCKY_TTS_FISH_MODEL`.
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path

from .backends import Backend, SynthesisResult


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[fish-tts] {msg}\n")
    sys.stderr.flush()


DEFAULT_FISH_MODEL = "mlx-community/fish-audio-s2-pro-bf16"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"


class FishTTSBackend(Backend):
    """Fish Audio S2 Pro with ICL voice cloning, non-streaming."""

    name = "fish-audio"
    supports_streaming = False

    def __init__(
        self,
        model_id: str | None = None,
        ref_audio_path: str | None = None,
        ref_text: str | None = None,
    ) -> None:
        self.model_id = (
            model_id
            or os.environ.get("ROCKY_TTS_FISH_MODEL")
            or DEFAULT_FISH_MODEL
        )
        self.ref_audio_path = ref_audio_path or self._resolve_ref_audio()
        self.ref_text = (
            ref_text
            or os.environ.get("ROCKY_TTS_REF_TEXT")
            or self._resolve_ref_text()
        )
        self._loaded = False
        self._model = None
        self._ref_audio_array = None  # cached mx.array

    # ------------------------------------------------------------------
    # Reference resolution — same convention as Qwen3TTSBackend
    # ------------------------------------------------------------------

    def _resolve_ref_audio(self) -> str | None:
        env = os.environ.get("ROCKY_TTS_REF_AUDIO")
        if env and Path(env).is_file():
            return env
        for name in ("reference.wav", "sample.wav"):
            candidate = DEFAULT_REF_DIR / name
            if candidate.is_file():
                return str(candidate)
        return None

    def _resolve_ref_text(self) -> str | None:
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

    # ------------------------------------------------------------------
    # Model loading
    # ------------------------------------------------------------------

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        from mlx_audio.tts.utils import load_model  # type: ignore

        self._model = load_model(self.model_id)
        # Fish requires BOTH a reference clip AND its transcript for
        # ICL cloning. If only one is present, the model still produces
        # output but with inconsistent voice — disable cloning entirely
        # so the user gets a coherent default voice instead of partial
        # cloning artefacts. Easier to debug, easier to onboard.
        if self.ref_audio_path and not self.ref_text:
            _stderr(
                f"ref_text missing for {self.ref_audio_path!r} — "
                f"disabling cloning. Place a .txt sibling next to the "
                f"reference WAV."
            )
            self.ref_audio_path = None

        self._load_ref_array()
        self._loaded = True

    def _load_ref_array(self) -> None:
        """Resolve the reference WAV path to an mx.array at the model's
        native sample rate. fish_qwen3_omni's `generate` requires an
        `mx.array` for `ref_audio` — passing a path raises inside
        `_prepare_reference_prompt` because it indexes `.ndim`. Cached
        on the backend so each synthesise call doesn't repay the
        resample cost."""
        self._ref_audio_array = None
        if not self.ref_audio_path:
            return
        try:
            from mlx_audio.utils import load_audio  # type: ignore
            # `volume_normalize=False` matches `mlx_audio.tts.generate`'s
            # default; normalising tends to over-amplify quiet clips and
            # changes the speaker's perceived loudness in cloned output.
            self._ref_audio_array = load_audio(
                self.ref_audio_path,
                sample_rate=int(getattr(self._model, "sample_rate", 44_100)),
                volume_normalize=False,
            )
        except Exception as exc:  # noqa: BLE001
            _stderr(
                f"failed to load reference audio {self.ref_audio_path!r}: "
                f"{type(exc).__name__}: {exc} — falling back to default voice."
            )
            self._ref_audio_array = None

    def warm_up(self) -> None:
        try:
            self._ensure_loaded()
        except Exception as exc:  # noqa: BLE001
            _stderr(f"warm-up deferred — model not yet ready: {exc}")

    # ------------------------------------------------------------------
    # Voice-reference persistence (Rocky cockpit calls this when the
    # user records a new sample). Same convention as Qwen3TTSBackend so
    # both backends honour the cockpit's `set_voice_ref` flow.
    # ------------------------------------------------------------------

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        DEFAULT_REF_DIR.mkdir(parents=True, exist_ok=True)
        path = DEFAULT_REF_DIR / f"{voice_ref_id}.wav"
        path.write_bytes(wav_bytes)
        self.ref_audio_path = str(path)
        # Re-read the paired transcript on the new path. If the user
        # supplied a new clip via the cockpit without a transcript,
        # leave the prior `ref_text` (matched on the old clip's
        # filename) but warn — quality will degrade.
        sibling = path.with_suffix(".txt")
        if sibling.is_file():
            try:
                self.ref_text = sibling.read_text(encoding="utf-8").strip() or None
            except OSError:
                pass
        if self._loaded:
            self._load_ref_array()

    # ------------------------------------------------------------------
    # Full-WAV synthesis (Fish doesn't stream)
    # ------------------------------------------------------------------

    def synthesize(
        self,
        text: str,
        voice_ref_id: str | None,
    ) -> SynthesisResult:
        self._ensure_loaded()

        # Fish's `generate` yields one `GenerationResult` per internal
        # chunk (split by `chunk_length=300` bytes by default). For
        # Rocky's short utterances this is almost always a single
        # segment, but we accumulate to support longer replies too.
        # Note: `stream=True` raises NotImplementedError inside Fish
        # (see fish_speech.py:953) — that's why `supports_streaming`
        # is False on this backend.
        pcm_chunks: list[bytes] = []
        sample_rate = int(getattr(self._model, "sample_rate", 44_100))
        for result in self._model.generate(  # type: ignore[union-attr]
            text=text,
            ref_audio=self._ref_audio_array,
            ref_text=self.ref_text,
            stream=False,
            verbose=False,
        ):
            audio = getattr(result, "audio", result)
            pcm_chunks.append(_to_int16_bytes(audio))
            sample_rate = int(getattr(result, "sample_rate", sample_rate))

        if not pcm_chunks:
            _stderr(f"generate yielded no audio for text {text!r}")

        pcm_concat = b"".join(pcm_chunks)
        wav_bytes = _wrap_pcm_in_wav(pcm_concat, sample_rate=sample_rate)
        duration_s = len(pcm_concat) / (sample_rate * 2)  # int16 mono
        return SynthesisResult(
            wav_bytes=wav_bytes,
            sample_rate=sample_rate,
            channels=1,
            duration_s=duration_s,
        )


# ---------------------------------------------------------------------------
# Helpers (mirrors Qwen3TTSBackend helpers; kept local to avoid a
# circular dep on a shared utility module)
# ---------------------------------------------------------------------------


def _to_int16_bytes(audio) -> bytes:
    try:
        import numpy as np  # type: ignore
    except ImportError:
        result = bytearray()
        for sample in audio:
            v = max(-1.0, min(1.0, float(sample)))
            result.extend(struct.pack("<h", int(v * 32767)))
        return bytes(result)
    arr = np.asarray(audio, dtype="float32")
    arr = np.clip(arr, -1.0, 1.0)
    return (arr * 32767).astype("<i2").tobytes()


def _wrap_pcm_in_wav(pcm: bytes, sample_rate: int = 24_000) -> bytes:
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
    header += struct.pack("<I", 16)
    header += struct.pack("<H", 1)
    header += struct.pack("<H", channels)
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", byte_rate)
    header += struct.pack("<H", block_align)
    header += struct.pack("<H", bits)
    header += b"data"
    header += struct.pack("<I", data_size)
    return bytes(header) + pcm
