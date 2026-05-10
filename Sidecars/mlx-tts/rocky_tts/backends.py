"""TTS backends share one tiny interface so the runner doesn't care which
implementation is active.

v0.2 M1 dropped the `say` macOS-bundled backend. Chatterbox is the only
shipped backend; M6 swaps the model to Qwen3-TTS-12Hz with streaming."""

from __future__ import annotations

import os
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

    Streaming chunked synthesis is the M6 enhancement (the wire protocol
    already supports `stream` envelopes via SidecarHost); for the M1
    snapshot the runner blocks on the full WAV and ships it as the
    `result`.
    """

    name: str

    @abstractmethod
    def synthesize(self, text: str, voice_ref_id: str | None) -> SynthesisResult: ...

    def set_voice_ref(self, voice_ref_id: str, wav_bytes: bytes) -> None:
        # Default: no-op for backends that don't support voice cloning.
        pass

    def warm_up(self) -> None:
        pass


def make_backend() -> Backend:
    """Pick the backend per ROCKY_TTS_BACKEND env var.

    Names recognised:
      `chatterbox` (default) — Chatterbox-Turbo FP16 via mlx-audio.

    Any other value (including the legacy `say`) raises — `say` was
    dropped in v0.2 M1 because it masked "the venv didn't build" with
    a robotic monotone. Run `./Sidecars/mlx-tts/setup.sh` (with the
    `[mlx]` extras) before launching Rocky.
    """
    name = os.environ.get("ROCKY_TTS_BACKEND", "chatterbox").lower()
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
    raise ValueError(
        f"unknown TTS backend: {name!r}. The `say` backend was dropped in "
        f"v0.2 M1; install the chatterbox venv via "
        f"`FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh`."
    )
