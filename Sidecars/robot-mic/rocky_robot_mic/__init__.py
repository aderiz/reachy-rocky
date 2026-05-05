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

from .runner import main  # re-export for `python -m rocky_robot_mic`

__all__ = ["main"]
