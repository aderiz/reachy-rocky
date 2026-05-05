"""Chatterbox-Turbo FP16 backend (mlx-community/chatterbox-turbo-fp16 via mlx-audio).

Voice cloning: pass `ref_audio` (WAV path) + `ref_text` (transcript) to
`mlx_audio.tts.generate.generate_audio` and Chatterbox emits speech in
the speaker's voice.

Cold start downloads the FP16 model (~3 GB) and caches under
`~/.cache/huggingface/`. First synthesis loads the model into MLX
(~5–10 s on M-series); subsequent calls reuse the in-memory model and
are fast (~real-time-x on a 32-token utterance).
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from .backends import Backend, SynthesisResult


CHATTERBOX_MODEL = "mlx-community/chatterbox-turbo-fp16"
DEFAULT_REF_DIR = Path.home() / "Library" / "Application Support" / "Rocky" / "voice"


class ChatterboxBackend(Backend):
    name = "chatterbox"

    def __init__(
        self,
        model_id: str = CHATTERBOX_MODEL,
        ref_audio_path: str | None = None,
        ref_text: str | None = None,
    ) -> None:
        self.model_id = model_id
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

    def warm_up(self) -> None:
        # `generate_audio` loads the model lazily on first call. We could
        # eagerly load via `mlx_audio.tts.generate.load_model`, but that
        # blocks the sidecar startup for ~10 s. Instead we let the first
        # synthesize() pay the cost — the SidecarHost ready event already
        # tells Swift the runner is alive.
        pass

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        # Persist a new reference WAV to disk so subsequent synthesize()
        # calls pick it up. Caller can also write the matching transcript
        # to <name>.txt; otherwise mlx-audio falls back to its built-in
        # whisper to auto-transcribe the reference.
        DEFAULT_REF_DIR.mkdir(parents=True, exist_ok=True)
        path = DEFAULT_REF_DIR / f"{voice_ref_id}.wav"
        path.write_bytes(wav_bytes)
        self.ref_audio_path = str(path)
        # If a transcript exists in this dir under the same name, use it.
        txt = path.with_suffix(".txt")
        if txt.exists():
            self.ref_text = txt.read_text().strip()
        else:
            # Let mlx-audio's built-in STT auto-transcribe on first use.
            self.ref_text = None

    def synthesize(self, text: str, voice_ref_id: str | None) -> SynthesisResult:
        # Late import so `say` users don't pay the mlx-audio import cost.
        from mlx_audio.tts.generate import generate_audio

        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            generate_audio(
                text=text,
                model=self.model_id,
                ref_audio=self.ref_audio_path,
                ref_text=self.ref_text,
                output_path=str(out_dir),
                file_prefix="rocky",
                audio_format="wav",
                save=True,
                play=False,
                verbose=False,
            )
            wavs = sorted(out_dir.glob("rocky*.wav"))
            if not wavs:
                raise RuntimeError("chatterbox produced no WAV output")
            data = wavs[0].read_bytes()

        # mlx-audio writes 24 kHz mono Int16 by default for chatterbox-turbo.
        return SynthesisResult(
            wav_bytes=data,
            sample_rate=24_000,
            channels=1,
            duration_s=_estimate_wav_duration(data, sr=24_000),
        )


def _estimate_wav_duration(data: bytes, sr: int) -> float:
    if len(data) < 44:
        return 0.0
    pcm_bytes = max(0, len(data) - 44)
    return pcm_bytes / (sr * 2)  # 16-bit mono
