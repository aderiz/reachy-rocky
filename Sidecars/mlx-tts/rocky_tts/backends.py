"""TTS backends share one tiny interface so the runner doesn't care which
implementation is active."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class SynthesisResult:
    wav_bytes: bytes
    sample_rate: int
    channels: int
    duration_s: float


class Backend(ABC):
    """Implementations return a complete WAV (LEI16 mono) per utterance.

    Streaming chunked synthesis is a future enhancement (the wire protocol
    already supports `stream` envelopes via SidecarHost); for v1 the runner
    blocks on the full WAV and ships it as the `result`.
    """

    name: str

    @abstractmethod
    def synthesize(self, text: str, voice_ref_id: str | None) -> SynthesisResult: ...

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        # Default: no-op for backends that don't support voice cloning.
        pass

    def warm_up(self) -> None:
        pass


class SayBackend(Backend):
    """macOS `say` backend. Always available; no Python deps."""

    name = "say"

    def __init__(self, voice: str | None = None, rate: int | None = None) -> None:
        self.voice = voice or os.environ.get("ROCKY_TTS_VOICE")
        self.rate = rate or int(os.environ.get("ROCKY_TTS_RATE", "180"))

        for tool in ("say", "afconvert"):
            if shutil.which(tool) is None:
                raise RuntimeError(f"`{tool}` not found on PATH; macOS only")

    def synthesize(self, text: str, voice_ref_id: str | None) -> SynthesisResult:
        # `say` doesn't support cloned voices (voice_ref_id is ignored).
        with tempfile.TemporaryDirectory() as td:
            aiff = os.path.join(td, "out.aiff")
            wav = os.path.join(td, "out.wav")
            cmd = ["say", "-o", aiff, "-r", str(self.rate)]
            if self.voice:
                cmd += ["-v", self.voice]
            cmd += ["--", text]
            subprocess.run(cmd, check=True)
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav],
                check=True,
            )
            data = open(wav, "rb").read()

        # WAV header: bytes 40-44 = data chunk size; bytes 22-24 = channels;
        # bytes 24-28 = sample rate. We trust afconvert produced LEI16 mono 16k.
        return SynthesisResult(
            wav_bytes=data,
            sample_rate=16000,
            channels=1,
            duration_s=_estimate_wav_duration(data),
        )


def _estimate_wav_duration(data: bytes) -> float:
    """Rough duration from WAV bytes; LEI16 mono 16 kHz is 32_000 bytes/sec."""
    if len(data) < 44:
        return 0.0
    pcm_bytes = max(0, len(data) - 44)
    return pcm_bytes / 32_000.0


def make_backend() -> Backend:
    """Pick the backend per ROCKY_TTS_BACKEND env var.

    Names:
      `say`        — macOS bundled TTS (default; no Python deps).
      `chatterbox` — Chatterbox-Turbo FP16 via mlx-audio (voice cloning).
    """
    name = os.environ.get("ROCKY_TTS_BACKEND", "say").lower()
    if name == "say":
        return SayBackend()
    if name in {"chatterbox", "chatterbox-turbo", "chatterbox-fp16",
                "chatterbox-turbo-fp16", "mlx"}:
        try:
            from .chatterbox_backend import ChatterboxBackend
            return ChatterboxBackend()
        except ImportError as exc:
            raise RuntimeError(
                f"Chatterbox backend requested but mlx-audio is not installed "
                f"(install with `FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh`): {exc}"
            )
    raise ValueError(f"unknown backend: {name}")
