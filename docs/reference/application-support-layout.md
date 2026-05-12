---
title: Application Support layout
type: reference
status: current
last_updated: 2026-05-12
sources:
  - Sources/Rocky/AppServices.swift
  - Sources/SidecarHost/SidecarSupervisor.swift
  - Sources/Perception/FaceLibrary.swift
  - Sidecars/mlx-tts/rocky_tts/backends.py
tags: [storage, application-support, on-disk, faces, voice, sidecars]
---

# Application Support layout

The mutable state Rocky owns on the user's Mac lives under:

```
~/Library/Application Support/Rocky/
```

Bundle ID `ai.amplified.Rocky`. The directory is created lazily by
whichever subsystem writes first — there's no startup-time
provisioning. Everything below is created on demand and survives
launches.

```
~/Library/Application Support/Rocky/
├── Memory/                 — mempalace's ChromaDB persistence
├── Models/                 — model assets that don't belong in a venv
├── sidecars/               — per-sidecar venvs + caches
│   ├── brain/.venv/        — mlx-vlm + Qwen3-VL
│   ├── mlx-stt/.venv/      — mlx-whisper + whisper-large-v3-mlx
│   ├── mlx-tts/.venv/      — mlx-audio + Chatterbox/Qwen3-TTS/Fish/...
│   ├── mempalace/.venv/    — ChromaDB-backed memory
│   ├── robot-mic/.venv/    — WS subscriber to the on-bot relay
│   └── robot-camera/.venv/ — WS subscriber to the on-bot relay
├── voice/                  — voice-clone reference clip(s)
│   ├── reference.wav       — preferred reference (3–10 s, mono, any sr)
│   ├── reference.txt       — exact transcript of reference.wav
│   ├── sample.wav          — fallback if reference.* absent
│   └── sample.txt          — fallback transcript
└── face-library.json       — enrolled-face feature-print store
```

## What each path is for

### `Memory/`

The mempalace sidecar's persistence root — a ChromaDB collection
plus auxiliary files. Each conversation turn writes a "drawer"; the
sidecar's `recall` RPC reads the top-K matches and feeds them to
`CognitionEngine` before each turn (if
`settings.memoryRecallEnabled` is true).

Wipe to reset Rocky's memory of past turns. Doesn't affect persona,
settings, or face enrollments.

### `Models/`

Reserved for model assets that don't belong inside a sidecar venv
(e.g. CoreML models downloaded at first run). Currently used by
`SileroVAD` (`.mlmodel` files when present). Sidecars keep their
own model caches inside `<sidecar>/.venv/` or under the OS-default
Hugging Face cache (`~/.cache/huggingface/`).

### `sidecars/<name>/.venv/`

Per-sidecar Python virtual environment, built by the
`./Sidecars/<name>/setup.sh` script using `uv venv` +
`uv pip install`.

`AppServices.locateSidecarDir(named:)` and the manifest path
resolver in `SidecarSupervisor` read from
`SidecarSupervisor.defaultVenvDir(for: <name>)` which returns this
path. The supervisor checks whether `bin/python` exists inside the
venv to decide whether the sidecar is "installable" — that's what
gates the auto-detection of optional features (e.g. MLX-VLM brain,
MLX-Whisper STT).

To force a fresh setup:

```bash
rm -rf "$HOME/Library/Application Support/Rocky/sidecars/<name>/.venv"
./Sidecars/<name>/setup.sh
```

The TTS sidecar caches model weights inside its venv as well, so
deleting the venv re-downloads ~3.5 GB on next launch.

### `voice/`

Voice-clone reference material. Each TTS backend (Chatterbox,
Qwen3-TTS, Fish, Sesame, Higgs) reads from this directory to pick
the user's reference clip:

1. First-preference: `reference.wav` + `reference.txt`.
2. Fallback: `sample.wav` + `sample.txt`.

The `.txt` file must contain the exact transcript of the audio —
ICL cloning matches text-against-audio to lock the speaker
embedding. Mismatched transcripts produce drift.

Recommended clip parameters:

- **Duration**: 3–10 seconds. Longer clips degrade ICL conditioning.
- **Content**: Natural conversational speech. Avoid singing,
  whispering, or unusual prosody unless that's the target voice.
- **Channels**: Mono.
- **Sample rate**: Any — sidecars resample as needed.
- **Format**: WAV. PCM, 16-bit, no compression.

To swap voices, drop a new `reference.wav` + `reference.txt` in and
restart the TTS sidecar (or call its `set_voice_ref` RPC if the
backend supports hot-swap — currently Chatterbox + Qwen3-TTS do).

### `face-library.json`

Enrolled faces — Apple Vision feature-print vectors plus per-person
metadata (display name, pronunciation, enrolled-at timestamp). Read
+ written by `FaceLibrary` (`Sources/Perception/FaceLibrary.swift`).

Each entry shape:

```json
{
  "id": "<uuid>",
  "displayName": "Ade",
  "pronunciation": "",
  "featurePrints": [<base64 of FeaturePrintObservation data> ...],
  "enrolledAt": "2026-05-08T19:24:11Z"
}
```

`MacFaceTracker` looks up identity by matching the live detection's
feature-print against every enrolled person's stored prints; the
acceptance threshold is `settings.faceMatchThreshold`
(see [settings-store](settings-store.md)). The match is the
nearest-neighbour print, gated by the threshold.

To reset face enrollments without touching the rest of Rocky's
state, delete this file. The Faces tab in Settings is the
user-facing path.

## Reset recipes

Common cases:

| Goal | Command |
|---|---|
| Wipe all user-visible settings | `defaults delete ai.amplified.Rocky` |
| Reset mic permission TCC | `tccutil reset Microphone ai.amplified.Rocky` |
| Reset speech-recognition TCC | `tccutil reset SpeechRecognition ai.amplified.Rocky` |
| Force a sidecar reinstall | `rm -rf "$HOME/Library/Application Support/Rocky/sidecars/<name>/.venv"` |
| Reset Rocky's memory | `rm -rf "$HOME/Library/Application Support/Rocky/Memory"` |
| Reset face enrollments | `rm "$HOME/Library/Application Support/Rocky/face-library.json"` |
| Swap voice clone | replace `voice/reference.wav` + `reference.txt`; restart TTS sidecar |
| Nuke everything | `rm -rf "$HOME/Library/Application Support/Rocky"` + `defaults delete ai.amplified.Rocky` |

## What's *not* here

A few things that look like they might be in Application Support
but live elsewhere:

- **Persona text** — in UserDefaults under `rocky.persona`. See
  [settings-store](settings-store.md).
- **Hugging Face model cache** — `~/.cache/huggingface/` (standard
  HF location). Shared across sidecars + other HF-aware tooling.
- **App build artefacts** — `build/Rocky.app` (or `.build/` for
  swift-build raw binaries) inside the repo.
- **Logs** — Rocky doesn't log to disk; everything's in `LogBus`
  and the Inspector → Logs view. The bot's daemon logs to
  `journalctl` on-bot.

## See also

- [Settings store](settings-store.md) — the UserDefaults side of
  the configuration.
- [Sidecar convention](../concepts/sidecar-convention.md) — how
  venvs under `sidecars/` are bootstrapped + supervised.
- [App Services](../concepts/app-services.md) — what reads from
  here on launch.
