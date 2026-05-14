"""Chatterbox 8-bit backend (mlx-community/chatterbox-8bit via mlx-audio).

Voice cloning: pass `ref_audio` (WAV path) + `ref_text` (transcript) to
`mlx_audio.tts.generate.generate_audio` and Chatterbox emits speech in
the speaker's voice.

Why 8-bit instead of fp16: the 8-bit Chatterbox release synthesises at
~0.15× RTF on Apple Silicon (vs ~0.37× for fp16, ~1.44× for
Qwen3-TTS-12Hz-1.7B-bf16). It's the fastest cloner available on
mlx-audio 0.4.3 and the quality drop from fp16 → 8-bit is
inaudible on conversational speech. Override via
`ROCKY_TTS_CHATTERBOX_MODEL=mlx-community/chatterbox-fp16` if you'd
rather have the larger model.

Cold start downloads the 8-bit model (~1 GB) and caches under
`~/.cache/huggingface/`. First synthesis loads the model into MLX
(~10–15 s — the 8-bit dequant pass is one-time); subsequent calls
reuse the in-memory model.
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path

from .backends import Backend, SynthesisResult


DEFAULT_CHATTERBOX_MODEL = "mlx-community/chatterbox-8bit"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[chatterbox] {msg}\n")
    sys.stderr.flush()


class ChatterboxBackend(Backend):
    name = "chatterbox"

    def __init__(
        self,
        model_id: str | None = None,
        ref_audio_path: str | None = None,
        ref_text: str | None = None,
    ) -> None:
        self.model_id = (
            model_id
            or os.environ.get("ROCKY_TTS_CHATTERBOX_MODEL")
            or DEFAULT_CHATTERBOX_MODEL
        )
        # Default reference: ~/Library/Application Support/Rocky/voice/sample.{wav,txt}
        env_ref = os.environ.get("ROCKY_TTS_REF_AUDIO")
        env_text = os.environ.get("ROCKY_TTS_REF_TEXT")
        if ref_audio_path is None and env_ref:
            ref_audio_path = env_ref
        if ref_audio_path is None:
            default = DEFAULT_REF_DIR / "sample.wav"
            if default.exists():
                ref_audio_path = str(default)
        if ref_text is None and env_text:
            ref_text = env_text
        if ref_text is None and ref_audio_path:
            txt = Path(ref_audio_path).with_suffix(".txt")
            if txt.exists():
                ref_text = txt.read_text().strip()
        self.ref_audio_path = ref_audio_path
        self.ref_text = ref_text
        self._model = None
        self._audio_prompt = None      # cached mx.array reference
        self._audio_prompt_sr = 24_000

    def warm_up(self) -> None:
        try:
            self._ensure_loaded()
        except Exception as exc:  # noqa: BLE001
            _stderr(f"warm-up deferred — model not yet ready: {exc}")

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        # Lazy import — mlx_audio is heavy.
        from mlx_audio.tts.utils import load_model  # type: ignore
        self._model = load_model(self.model_id)
        sr = int(getattr(self._model, "sample_rate", 24_000))
        self._audio_prompt_sr = sr
        self._load_ref_array()
        _stderr(f"model loaded id={self.model_id} sample_rate={sr}")

    def _load_ref_array(self) -> None:
        """Pre-resolve the reference WAV to an mx.array at the model's
        native rate. Avoids paying load_audio's resample cost on every
        synthesise call.
        """
        self._audio_prompt = None
        if not self.ref_audio_path:
            return
        try:
            from mlx_audio.utils import load_audio  # type: ignore
            self._audio_prompt = load_audio(
                self.ref_audio_path,
                sample_rate=self._audio_prompt_sr,
            )
        except Exception as exc:  # noqa: BLE001
            _stderr(
                f"failed to load reference audio {self.ref_audio_path!r}: "
                f"{type(exc).__name__}: {exc} — cloning disabled."
            )
            self._audio_prompt = None

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        DEFAULT_REF_DIR.mkdir(parents=True, exist_ok=True)
        path = DEFAULT_REF_DIR / f"{voice_ref_id}.wav"
        path.write_bytes(wav_bytes)
        self.ref_audio_path = str(path)
        txt = path.with_suffix(".txt")
        if txt.exists():
            self.ref_text = txt.read_text().strip()
        else:
            self.ref_text = None
        # Invalidate + reload the cached mx.array.
        self._audio_prompt = None
        if self._model is not None:
            self._load_ref_array()

    def synthesize(self, text: str, voice_ref_id: str | None) -> SynthesisResult:
        """Call `Model.generate(ref_audio=...)` directly rather than
        going through `mlx_audio.tts.generate.generate_audio`.

        Why bypass `generate_audio`: it defaults `voice='af_heart'`
        (a Kokoro preset) and passes that *alongside* the reference
        to the model. Chatterbox honours both, with the preset
        dominating — the cloned voice ends up diluted toward
        'af_heart' and synth slows to ~1× RTF. Direct call with just
        the reference kwarg clones cleanly at ~0.15× RTF.

        Why `ref_audio` + `sample_rate` instead of `audio_prompt` +
        `audio_prompt_sr`: the **chatterbox-turbo** model (a separate
        mlx_audio module — `chatterbox_turbo/chatterbox_turbo.py`)
        only accepts `ref_audio` + `sample_rate`; it doesn't have an
        `audio_prompt` kwarg. Regular `chatterbox` accepts both
        names (`ref_audio` is documented as an alias for
        `audio_prompt`). So `ref_audio` + `sample_rate` is the
        cross-compatible pair — works for `chatterbox`,
        `chatterbox-fp16`, `chatterbox-8bit`, and `chatterbox-turbo*`.
        Without this fix, the turbo model silently ignored the
        cloning kwargs and produced its default voice instead of
        the user's clone.
        """
        self._ensure_loaded()
        assert self._model is not None

        kwargs: dict = {"text": text}
        if self._audio_prompt is not None:
            kwargs["ref_audio"] = self._audio_prompt
            kwargs["sample_rate"] = self._audio_prompt_sr

        results = list(self._model.generate(**kwargs))
        if not results:
            raise RuntimeError("chatterbox produced no audio")

        # Concatenate any multi-segment output (Chatterbox splits on
        # newlines by default; for single-sentence input there's just
        # one segment).
        if len(results) == 1:
            audio = results[0].audio
            sample_rate = int(results[0].sample_rate)
        else:
            import mlx.core as mx  # local import; module already loaded
            audio = mx.concatenate([r.audio for r in results], axis=0)
            sample_rate = int(results[0].sample_rate)

        pcm = _to_int16_bytes(audio)
        wav_bytes = _wrap_pcm_in_wav(pcm, sample_rate=sample_rate)
        duration_s = len(pcm) / (sample_rate * 2)  # int16 mono
        return SynthesisResult(
            wav_bytes=wav_bytes,
            sample_rate=sample_rate,
            channels=1,
            duration_s=duration_s,
        )


# ---------------------------------------------------------------------------
# Helpers (mirror Qwen3 / Fish backends — kept local to avoid a circular
# dep on a shared module)
# ---------------------------------------------------------------------------


def _to_int16_bytes(audio) -> bytes:
    try:
        import numpy as np  # type: ignore
    except ImportError:
        result = bytearray()
        for s in audio:
            v = max(-1.0, min(1.0, float(s)))
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
