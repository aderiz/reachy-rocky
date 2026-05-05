"""Rocky TTS sidecar.

Two pluggable backends share one wire protocol:

  * `say`        — macOS's bundled TTS via subprocess. No Python deps.
                   Default; useful for smoke-testing the wire path.
  * `chatterbox` — Chatterbox-Turbo FP16 via mlx-audio (voice cloning).
                   Activated when the user installs the `mlx` extras and
                   sets ROCKY_TTS_BACKEND=chatterbox. Reference WAV +
                   optional transcript live in
                   ~/Library/Application Support/Rocky/voice/.

`runner.py` exposes:

  synthesize(text: str, voice_ref_id: Optional[str]) -> result with WAV bytes
  set_voice_ref(name: str, wav_b64: str) -> ack
  health() -> { backend, voice_ref_id }
"""

from .backends import Backend, SayBackend

__all__ = ["Backend", "SayBackend"]
