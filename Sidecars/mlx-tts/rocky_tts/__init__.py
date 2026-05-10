"""Rocky TTS sidecar.

One backend (since v0.2 M1):

  * `chatterbox` — Chatterbox-Turbo FP16 via mlx-audio (voice cloning).
                   Reference WAV + optional transcript live in
                   ~/Library/Application Support/Rocky/voice/.

The legacy `say` backend was dropped in M1 because it masked "the venv
wasn't installed" with a robotic monotone; chatterbox-or-fail-closed.
M6 will swap the underlying model to Qwen3-TTS-12Hz for streaming.

`runner.py` exposes:

  synthesize(text: str, voice_ref_id: Optional[str]) -> result with WAV bytes
  set_voice_ref(name: str, wav_b64: str) -> ack
  health() -> { backend, voice_ref_id }
"""

from .backends import Backend

__all__ = ["Backend"]
