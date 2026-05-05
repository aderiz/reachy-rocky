"""Rocky TTS sidecar.

Two pluggable backends share one wire protocol:

  * `say`        — macOS's bundled TTS via subprocess. Placeholder for
                   wiring + smoke testing. No Python deps.
  * `f5-tts-mlx` — F5-TTS-MLX voice cloning (iOS 26 / Apple Silicon).
                   Activated when the user installs the `mlx` extras and
                   sets ROCKY_TTS_BACKEND=f5-tts-mlx.

`runner.py` exposes:

  synthesize(text: str, voice_ref_id: Optional[str]) -> result with WAV bytes
  set_voice_ref(name: str, wav_b64: str) -> ack
  health() -> { backend, voice_ref_id }
"""

from .backends import Backend, SayBackend

__all__ = ["Backend", "SayBackend"]
