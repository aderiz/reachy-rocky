"""Robot-mic sidecar.

Connects to the running Reachy Mini daemon via the `reachy_mini` SDK
(which auto-uses the WebRTC media backend when run remotely on the Mac)
and streams the 4-mic array's mono mix to Rocky over the Sidecar wire.

Wire output:
  {"event": "ready"}                                     — startup
  {"event": "audio", "payload": {                        — every chunk (~50 Hz)
      "samples_b64": <PCM16-LE mono base64>,
      "sample_rate": 16000,
      "channels": 1,
      "rms": <float>
   }}
  {"event": "doa", "payload": {                          — when speech detected
      "angle_rad": <float>, "is_speech": <bool>
   }}

Methods:
  start_recording(): start the audio stream.
  stop_recording():  pause; releases the daemon's audio device.
  health():          { connected, recording, sample_rate, channels }
"""

# Intentionally empty. Do NOT `from .runner import main` here — the
# sidecar is launched via `python -m rocky_robot_mic.runner`, and
# importing `runner` from `__init__.py` causes the runner module to be
# loaded twice (once as `rocky_robot_mic.runner`, once as `__main__`),
# yielding the `<frozen runpy>:128 RuntimeWarning: ... found in
# sys.modules after import of package ... prior to execution` warning.
# That double-import can leave GStreamer / threading state in a
# half-initialised condition and is suspected in the "green but
# silent" robot-mic symptom.

__all__: list[str] = []
