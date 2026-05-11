"""Qwen3-TTS-12Hz Base backend (mlx-community / Qwen3 via mlx-audio).

The "12Hz" label in the model name refers to the **codec token rate**
(12.5 codec tokens per second). The actual audio sample rate of the
output is **24 000 Hz** — this is what the model returns in every
`GenerationResult.sample_rate`. Our older docstrings claimed 16 kHz;
they were wrong.

Streaming: ~800 ms first-packet latency on Apple Silicon. Each
streaming chunk is a 1-D mx.array of float32 audio at 24 kHz; we
clip and convert to int16-LE PCM before yielding to Swift.

Voice cloning (ICL): the **Base** variant uses in-context-learning
voice cloning from a 3–10 s reference clip plus its verbatim
transcript. Both are required — `mlx_audio.tts.models.qwen3_tts`'s
`generate()` only routes to `_generate_icl` when BOTH `ref_audio`
and `ref_text` are non-None AND `speech_tokenizer.has_encoder` is
true (see qwen3_tts.py:1151-1155).

Critically: the **CustomVoice** sibling variant cannot clone — it
uses a fixed roster of pretrained speakers and demands a `voice=`
argument. Rocky's persona is voice-cloned, so we lock the model id
to a Base variant and refuse to load CustomVoice / VoiceDesign.

Defaults to `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16`; override
via `ROCKY_TTS_QWEN3_MODEL`. Reference clip path override via
`ROCKY_TTS_REF_AUDIO`; transcript override via `ROCKY_TTS_REF_TEXT`.

Both `synthesize` (full WAV) and `synthesize_stream` (chunked PCM)
paths are exposed; the runner picks based on caller method.
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path

from .backends import Backend, SynthesisResult


DEFAULT_QWEN3_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"
DEFAULT_REF_NAME = "reference.wav"
# Qwen3-TTS native output sample rate. Authoritative source: every
# `GenerationResult.sample_rate` returns this value
# (mlx_audio.tts.models.qwen3_tts.config.ModelConfig.sample_rate
# defaults to 24000). Hard-code as the empty-output fallback so a
# misbehaving model never produces a WAV with a stale 16 kHz header.
DEFAULT_OUTPUT_SAMPLE_RATE = 24_000


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[qwen3-tts] {msg}\n")
    sys.stderr.flush()


class Qwen3TTSBackend(Backend):
    """Qwen3-TTS-12Hz Base with ICL voice cloning.

    Returns the full WAV in one shot (non-streaming). We used to
    stream chunk-by-chunk via `model.generate(stream=True)`, but the
    streaming decoder in mlx-audio 0.4.3 produces audibly lower-
    quality output than the non-streaming `decode` path for the same
    generated codes — verified by a deterministic A/B (greedy
    sampling, identical inputs): both paths produce identical-length
    audio but the streaming version has only 0.78 normalised
    cross-correlation with non-streaming, audible as "the cloned
    voice doesn't sound like the reference".
    And we were paying that quality cost for nothing —
    `StreamingTTS.playToRobot` accumulates every chunk before
    uploading the WAV to the daemon and calling `play_sound`, so
    end-to-end time-to-audio is identical either way. The only thing
    streaming bought us was the `isSpeaking` UI flicker firing ~3 s
    earlier. Not worth it.
    """

    name = "qwen3-tts"
    supports_streaming = False

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
        # Pre-load early so the first synthesise call doesn't bear
        # the path → mx.array resample cost. Re-loaded only when
        # `set_voice_ref` swaps the reference (see `_load_ref_array`).
        self.ref_audio_path = ref_audio_path or self._resolve_ref_audio()
        self.ref_text = (
            ref_text
            or os.environ.get("ROCKY_TTS_REF_TEXT")
            or self._resolve_ref_text()
        )
        self._loaded = False
        self._model = None
        # Cached mx.array form of the reference audio at the model's
        # native sample rate. Lives between calls so each generate()
        # doesn't repay load_audio's resample cost.
        self._ref_audio_array = None
        self._validate_model_id()

    # ------------------------------------------------------------------
    # Model-id sanity
    # ------------------------------------------------------------------

    def _validate_model_id(self) -> None:
        """ICL voice-cloning is a Base-only feature. CustomVoice +
        VoiceDesign variants demand a `voice=` / `instruct=` arg
        which we don't pass — they'd ValueError on first synth.
        Surface a clear warning at construction instead of silent
        failure later.
        """
        lowered = self.model_id.lower()
        if "customvoice" in lowered or "custom-voice" in lowered:
            _stderr(
                f"WARN: model id {self.model_id!r} is a CustomVoice variant; "
                f"Rocky's voice-cloning path expects a Base variant. "
                f"Override via ROCKY_TTS_QWEN3_MODEL to a *-Base-* model."
            )
        elif "voicedesign" in lowered or "voice-design" in lowered:
            _stderr(
                f"WARN: model id {self.model_id!r} is a VoiceDesign variant; "
                f"Rocky's voice-cloning path expects a Base variant."
            )

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
        non-ICL synthesis (it works, but the voice won't clone).
        """
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
        future synthesis to use it.

        Critically: re-read the paired transcript and reset the cached
        mx.array. Without this, ICL would keep the OLD `ref_text` against
        the NEW `ref_audio` — the alignment is wrong and the cloned
        voice degenerates (the symptom that motivated this rewrite).
        """
        DEFAULT_REF_DIR.mkdir(parents=True, exist_ok=True)
        path = DEFAULT_REF_DIR / f"{voice_ref_id}.wav"
        path.write_bytes(wav_bytes)
        self.ref_audio_path = str(path)
        sibling = path.with_suffix(".txt")
        if sibling.is_file():
            try:
                self.ref_text = sibling.read_text(encoding="utf-8").strip() or None
            except OSError:
                pass
        else:
            _stderr(
                f"set_voice_ref({voice_ref_id!r}): no sibling .txt found at "
                f"{sibling}. ICL cloning needs a matching transcript; the "
                f"old ref_text is retained but cloning quality will degrade."
            )
        # Invalidate the cached mx.array; will be re-loaded on next synth.
        self._ref_audio_array = None
        if self._loaded:
            self._load_ref_array()

    # ------------------------------------------------------------------
    # Model loading
    # ------------------------------------------------------------------

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        # Lazy import — mlx_audio is heavy. Done on first synth so the
        # supervisor's ready_event doesn't time out on a slow disk.
        from mlx_audio.tts.utils import load_model  # type: ignore

        self._model = load_model(self.model_id)
        self._loaded = True

        # Confirm the loaded model is actually a Base variant. If a
        # caller pinned a CustomVoice / VoiceDesign id by accident,
        # we'd otherwise fail later inside `generate` with a confusing
        # message about a missing `voice=` arg.
        tts_type = getattr(self._model.config, "tts_model_type", "base")
        if tts_type != "base":
            _stderr(
                f"WARN: loaded model reports tts_model_type={tts_type!r}; "
                f"ICL voice-cloning requires 'base'. Cloning will silently "
                f"fall through to the variant's default behaviour."
            )

        # Surface the sample rate so anyone reading the log can verify.
        sr = getattr(self._model, "sample_rate", DEFAULT_OUTPUT_SAMPLE_RATE)
        _stderr(
            f"model loaded id={self.model_id} type={tts_type} sample_rate={sr}"
        )

        self._load_ref_array()

    def _load_ref_array(self) -> None:
        """Resolve the reference WAV path to an mx.array at the model's
        native sample rate. mlx-audio's `generate()` accepts both a
        path and an mx.array (see qwen3_tts.py:1097-1098 — it calls
        `load_audio` internally when a path is passed), but doing the
        resample once and reusing the array eliminates the per-call
        IO + resample cost.

        Crucially the audio MUST be at the model's native rate before
        `extract_speaker_embedding` runs (qwen3_tts.py:265 raises
        ValueError otherwise). `load_audio(path, sample_rate=model.sr)`
        guarantees that.
        """
        self._ref_audio_array = None
        if not self.ref_audio_path:
            return
        try:
            from mlx_audio.utils import load_audio  # type: ignore
            sr = int(getattr(self._model, "sample_rate",
                              DEFAULT_OUTPUT_SAMPLE_RATE))
            self._ref_audio_array = load_audio(self.ref_audio_path,
                                                sample_rate=sr)
        except Exception as exc:  # noqa: BLE001
            _stderr(
                f"failed to pre-load reference audio "
                f"{self.ref_audio_path!r}: {type(exc).__name__}: {exc} — "
                f"falling back to per-call path resolve."
            )
            self._ref_audio_array = None

    def warm_up(self) -> None:
        try:
            self._ensure_loaded()
        except Exception as exc:  # noqa: BLE001
            _stderr(f"warm-up deferred — model not yet ready: {exc}")

    # ------------------------------------------------------------------
    # Full-WAV synthesis
    # ------------------------------------------------------------------

    def synthesize(
        self,
        text: str,
        voice_ref_id: str | None,
    ) -> SynthesisResult:
        self._ensure_loaded()

        # Prefer the pre-loaded mx.array. Fall back to the path so a
        # transient load_audio failure doesn't kill the synth.
        ref_audio = self._ref_audio_array
        if ref_audio is None:
            ref_audio = self.ref_audio_path

        # ICL only fires when BOTH ref_audio and ref_text are non-None.
        # Skip cloning entirely (rather than half-clone with mismatched
        # text) when the transcript is missing — produces a coherent
        # default voice instead of degenerate ICL output.
        if ref_audio is not None and not self.ref_text:
            _stderr(
                "no ref_text — skipping ICL; output will use the "
                "model's default voice."
            )
            ref_audio = None

        # `stream=False` routes to `_generate_icl` (or the default
        # base-model path) and yields a single `GenerationResult`
        # carrying the full audio. Per the deterministic A/B above
        # — the non-streaming decode produces audibly higher-quality
        # speech than streaming for the same codes, and we don't
        # benefit from streaming downstream anyway because
        # StreamingTTS.playToRobot already accumulates every chunk
        # before uploading.
        results = list(self._model.generate(  # type: ignore[union-attr]
            text=text,
            ref_audio=ref_audio,
            ref_text=self.ref_text,
            stream=False,
            verbose=False,
        ))
        if not results:
            _stderr(f"synthesize: model.generate yielded no results for {text!r}")
            return SynthesisResult(
                wav_bytes=_wrap_pcm_in_wav(b"",
                                            sample_rate=DEFAULT_OUTPUT_SAMPLE_RATE),
                sample_rate=DEFAULT_OUTPUT_SAMPLE_RATE,
                channels=1,
                duration_s=0.0,
            )

        # Concatenate any multi-segment output (the base-model path
        # may split on \n; ICL always returns a single segment).
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
# Helpers
# ---------------------------------------------------------------------------


def _to_int16_bytes(audio) -> bytes:
    """Convert an mlx / numpy float audio buffer to little-endian int16
    bytes, clipping to [-1.0, 1.0] to avoid wrap-around.
    """
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


def _wrap_pcm_in_wav(pcm: bytes, sample_rate: int = DEFAULT_OUTPUT_SAMPLE_RATE) -> bytes:
    """Wrap raw int16 mono PCM in a minimal WAV (RIFF) header so
    callers that expect WAV (legacy `synthesize` path) get one. Default
    SR is Qwen3-TTS's native 24 kHz; callers should pass the actual SR
    from `GenerationResult.sample_rate` rather than rely on the default.
    """
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
