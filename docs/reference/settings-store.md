---
title: SettingsStore — every persisted setting
type: reference
status: current
last_updated: 2026-05-12
sources:
  - Sources/Rocky/SettingsStore.swift
tags: [settings, userdefaults, persistence, persona]
---

# SettingsStore

Every user-visible knob in Rocky is persisted in
`UserDefaults.standard` under a `rocky.*` key namespace and surfaced
via `@Observable` properties on `SettingsStore`
(`Sources/Rocky/SettingsStore.swift:11`).

Each property uses the `didSet { save() }` pattern — touching the
value writes through immediately. `save()` writes every field
atomically (`SettingsStore.swift:380+`); there's no partial save.

## Reading + writing

```swift
@Environment(AppServices.self) private var services
let host = services.settings.robotHost
services.settings.faceMatchThreshold = 0.85
```

Mutations from background tasks need `await MainActor.run { ... }`
since `SettingsStore` is `@MainActor` (`SettingsStore.swift:10`).

For values that need to hot-apply to running services, call
`services.applySettings()` after the mutation. That re-pushes brain
config, persona, mic threshold, TTS config etc. to their owners
without an app relaunch. The robot endpoint
(`robotHost` + `robotPort`) is the lone exception — it's captured
at `AppServices.init` and requires a relaunch.

## Field inventory

Grouped by concern. Defaults shown where meaningful. Source lines
are the property declaration; the `Keys.*` constant + the
`init` / `save()` plumbing live in the bottom third of the file.

### Robot endpoint

| Field | Default | Notes |
|---|---|---|
| `robotHost` | `"reachy-mini.local"` | Bot mDNS or IP. Relaunch-required. |
| `robotPort` | `8000` | Daemon HTTP/WS port. Relaunch-required. |

### Brain / LLM

| Field | Default | Notes |
|---|---|---|
| `lmStudioURL` | `"http://localhost:1234/v1"` | LM Studio HTTP base. |
| `lmStudioModel` | `"gemma-4-e4b-it-mlx"` | Initial model id; hot-changeable from the picker. |
| `lmStudioApiKey` | `""` | Optional. |
| `brainBackend` | `"auto"` | `"auto"` / `"mlx-vlm"` / `"lm-studio"`. See [ADR 0005](../decisions/0005-brain-backend-protocol.md). |
| `brainModel` | `"mlx-community/Qwen3-VL-4B-Instruct-4bit"` | HF model id for the MLX-VLM brain sidecar. |
| `persona` | `Self.defaultPersona` | Rocky's voice / behaviour prompt. |
| `braveSearchAPIKey` | `""` | Brave Search subscription. Empty → `search_web` returns "no key configured". |

### Memory

| Field | Default | Notes |
|---|---|---|
| `memoryRecallEnabled` | `true` | When false, recall is skipped before each turn; writes still happen. |
| `memoryTopK` | `5` | Drawers pulled per recall. |

### Voice — mic + VAD

| Field | Default | Notes |
|---|---|---|
| `micSource` | `"robot"` if `robot-mic` venv exists else `"mac"` | Detected at first launch. |
| `micVADThreshold` | `0.008` | Energy-VAD RMS cutoff. Calibrated via the four-phase flow. |
| `micVADThresholdPrevious` | `=micVADThreshold` at first launch | Snapshot for the Settings "Revert" affordance. |
| `vadEngine` | `"auto"` | `"auto"` (Silero if installed, else energy) / `"silero"` / `"energy"`. |

### Voice — STT + wake

| Field | Default | Notes |
|---|---|---|
| `sttEngine` | `"auto"` | `"auto"` (MLX-Whisper → WhisperKit → Apple) / `"mlx-whisper"` / `"whisperkit"` / `"apple"`. |
| `wakeWord` | `"rocky"` | Lower-case; `WakeFilter` matches homophones too. |
| `wakeEngine` | `"stt"` | `"stt"` or `"porcupine"` (Porcupine slot is a stub). |
| `wakeOnPat` | `false` | Wake from sleep on a sustained loud sound. Default off to avoid TTS-bleed self-waking. |

### Voice — AddressFilter

See [address-filter](../concepts/address-filter.md) for the
decision logic these knobs feed.

| Field | Default | Notes |
|---|---|---|
| `addressFilterEnabled` | `true` | Master switch. |
| `addressMinSttConfidence` | `0.35` | Apple-Speech-only confidence floor. |
| `addressRMSFloor` | `0.012` | "Too quiet to be direct address." |
| `addressLoudnessRatio` | `4.0` | `peakRMS / roomNoise` cutoff. |
| `addressUserDoaCenterRad` | `0` | User's typical DoA from the bot. |
| `addressUserDoaToleranceRad` | `0.45` | Half-cone width (~26°). |
| `addressFaceEngageWindowS` | `3.0` | Face-recency window for engagement. |
| `convoWindowS` | `20.0` | Conversation window duration. WakeFilter no longer auto-extends. |
| `addressJunkPhrases` | `["thank you", "thanks", "you", "bye", "okay", ".", "…"]` | Hallucination deny-list. |
| `addressVerbPrefixes` | `["what","where",…]` | Engagement-via-verb-prefix list. |

### TTS

| Field | Default | Notes |
|---|---|---|
| `ttsBackend` | `"chatterbox"` | Detected at init; `"chatterbox"` / `"qwen3-tts"` / `"fish-audio-s2"` / `"higgs-audio-v2"` / `"sesame-csm"` / `"chatterbox-turbo"` / `"say"`. |
| `audioVolume` | `0.85` | 0.0–1.0; PCM is scaled before upload. |

### Face tracking + identification

| Field | Default | Notes |
|---|---|---|
| `faceMatchThreshold` | `1.0` | Apple Vision feature-print distance ceiling. Smaller = stricter. |
| `faceTrackerIdleSearchEnabled` | `false` | When true, the head pans on a slow Lissajous when no face is in frame. Off by default — read as uncanny otherwise. |

### UI state

| Field | Default | Notes |
|---|---|---|
| `firstRunCompleted` | `false` | True once the first-run overlay has been finished or skipped. Resettable via `Help → Show first run`. |
| `showToolCalls` | `true` | Inline tool-call rows in the chat transcript. |
| `visionChipWidth` / `visionChipHeight` | `240` / `150` | Persistent dimensions of the senses chip in the portrait. |

## Persona migration

Personas evolve. To prevent old installs being pinned to a
historical default, `currentPersonaVersion: Int = 6` lives at
`SettingsStore.swift:26`. The initializer checks the persisted
`Keys.personaVersion` value at `SettingsStore.swift:273-281` and:

- If `stored < current`, force-overwrites `persona` with
  `Self.defaultPersona`, writes through, and stamps the version.
- Otherwise honours whatever the user (or migration) saved.

This is **destructive of user-edited personas** on upgrade. Bump
`currentPersonaVersion` only when the new default is a real
improvement over the previous one. The full default persona lives in
`SettingsStore.swift:412+` (the `defaultPersona` multiline string).

## Keys layout

All keys live in a private `enum Keys` at the bottom of the file.
Naming convention: `rocky.<area>.<field>` (e.g.
`rocky.address.junk.phrases`, `rocky.mic.vad.threshold`,
`rocky.face.idle.search.enabled`). Stringified-array values use
`stringArray(forKey:)`; everything else uses `object(forKey:)` with
a Swift cast or `string(forKey:)`.

## Resetting

Wipe all Rocky settings:

```bash
defaults delete ai.amplified.Rocky
```

Re-launch the app and the initializer will write the defaults back.
The first-run overlay reappears (because `firstRunCompleted = false`
is the default).

## See also

- [App Services](../concepts/app-services.md) — how settings flow
  into running services.
- [Voice / listen pipeline](../concepts/voice-pipeline.md) —
  uses the mic + VAD + STT + AddressFilter settings.
- [Application Support layout](application-support-layout.md) —
  where the *non-UserDefaults* state lives.
