# Rocky

A native macOS app that acts as the **nervous system** for a
[Reachy Mini Wireless](https://www.pollen-robotics.com/reachy-mini/)
robot. Cognition (LM Studio brain), perception (face tracking, face
recognition), audition (mic + on-device speech-to-text), voice (cloned-
voice TTS), memory, and observability all run on the Mac. The robot
itself is reduced to a clean network endpoint — REST + WebSocket over
`reachy-mini.local:8000`.

The result: Rocky sits on the desk and behaves like a small, calm
co-worker. Says your name when it sees you. Holds your gaze. Answers
"what's on tomorrow?" by reading your calendar; "what's the weather?"
by checking your location. Speaks in its own voice. Goes to sleep
when you close the lid.

> Rocky is a personal project, not a Pollen Robotics product.

> 🪨 **About the name and voice.** This Rocky talks in the
> broken-English style of [Rocky in Andy Weir's *Project Hail
> Mary*](https://en.wikipedia.org/wiki/Project_Hail_Mary) — third
> person, no articles, base-form verbs, `, question?` suffix on
> questions, and a few catchphrases borrowed straight from the book
> ("Amaze amaze amaze!", "Fist my bump.", "It is time go."). Example
> exchange:
>
> > **You:** I just shipped the feature.
> >
> > **Rocky:** Amaze amaze amaze! Fist my bump.
>
> It's an intentional persona, defined as `defaultPersona` in
> [`Sources/Rocky/SettingsStore.swift`](Sources/Rocky/SettingsStore.swift).
> Edit in Settings → Brain → Persona if you'd rather a different
> voice. The robot the app drives is a Reachy Mini Wireless from
> Pollen Robotics; the *Rocky* name and voice are an homage, not
> affiliated with the book or its author.

> ⚠️ **Early stage — expect bugs.** Rocky is a personal experiment
> shared in case it's useful to others. It is not a finished product.
> Things will break: voice mishears, the LLM hallucinates tool calls,
> a sidecar will crash, the robot might twitch. The code changes
> daily. Settings and stored state may be reset between updates. Use
> at your own risk, with a robot you can stop quickly. Bug reports
> and PRs are welcome — just know what you're getting into.

---

## Key features

### Cognition

- **Local LLM brain** via [LM Studio](https://lmstudio.ai/)'s
  OpenAI-compatible API — no cloud dependency, no API key shipped to
  anyone else's GPU. Default model `gemma-4-e4b-it-mlx` runs on a
  16 GB Mac; swap in Qwen 2.5 7B / 3.6 27B via `Settings → Brain`.
- **Tool-using agent.** 17 tools wired up out of the box — robot
  motion (`look_at`, `play_emotion`, `wake_up`, `go_to_sleep`),
  voice (`say`, `stop_speaking`), and information (`get_current_time`,
  `get_weather`, `read_calendar`, `search_web`, `remember`).
- **Fenced-JSON fallback.** Recovers tool calls from models like
  Gemma that don't reliably emit OpenAI `tool_calls`.
- **Persona that holds.** Rocky speaks in the third-person,
  dropped-article style of Rocky from Andy Weir's *Project Hail
  Mary* ("Rocky see sun. Warm."), maintained via a versioned persona
  prompt that auto-migrates across upgrades. Editable in
  Settings → Brain → Persona.
- **Local memory** via the `mempalace` sidecar. Top-K relevant
  snippets are injected into each LLM turn; toggle off in
  `Settings → Memory`.

### Listening

- **Always-on wake word** ("Rocky"). 60-second conversation window
  auto-extends on each turn so follow-ups don't need the name.
- **On-device STT** via `SFSpeechRecognizer`. Nothing leaves the Mac.
- **Robot 4-mic array** (ReSpeaker via WebRTC) or **Mac built-in mic**.
  Pick in `Settings → Voice`.
- **Guided microphone calibration.** Speak for three seconds — Rocky
  measures your voice and the room and tunes the VAD threshold so
  quiet speech still triggers but a desk fan doesn't.
- **Echo gate.** Rocky doesn't transcribe his own voice as your
  next input.
- **Barge-in.** Talk over Rocky and his current TTS clip is cancelled.

### Voice (TTS)

- **Cloned voice** via Chatterbox FP16 (MLX). Drop a 5–10 s WAV in
  `~/Library/Application Support/Rocky/voice/` and Rocky learns your
  speaker. Falls back to the macOS `say` voice if Chatterbox isn't
  installed.
- **TTS normalisation gate** — strips template tokens, expands
  abbreviations (`17°C` → "seventeen degrees", `15 kph` → "fifteen
  kilometres per hour"), fixes acronyms, removes wrapping quotes.
- **Robot-side playback.** The robot's speaker is the audio sink,
  not the Mac, so Rocky's voice comes from the robot.

### Vision

- **Real-time face tracking** via Apple Vision
  (`VNDetectFaceRectanglesRequest`) on JPEG frames pulled from the
  `robot-camera` sidecar. State-driven world-frame target + EMA +
  critically-damped 50 Hz head controller — calm, never jerky. No
  ML model download required.
- **Face recognition** via Apple Vision feature-prints. Enrol a face
  with a name in `Settings → Faces`; Rocky greets you by name when
  he sees you.
- **Live camera preview** in the cockpit, with face-overlay rectangle
  and tracking-lock indicator.

### Motion + safety

- **Calm by default.** Default goto durations are slow (1.2 s) so the
  LLM can't accidentally produce twitchy motion. Velocity and joint-
  range limits enforced at the link layer.
- **Recorded-move library.** Pollen's emotion library
  (`play_emotion("excited")`, `("greeting")`, etc.) plus `wake_up`
  and `goto_sleep` choreographed transitions.
- **Single-instance guard.** Two Rocky processes can't fight over the
  robot — the second instance refuses to start.
- **Clean shutdown.** Quitting plays `goto_sleep` instead of an
  abrupt motor disable, so the robot rests its head before going limp.

### App + UX

- **Native Swift 6 macOS app**, signed and notarisable. Cockpit window
  with portrait (Stewart-platform 3D linkage that mirrors the real
  robot's head), live conversation, and a moment strip of recent
  events.
- **Menu bar presence.** Rocky lives in the menu bar even when the
  window is closed — five animated states (idle, listening, thinking,
  speaking, error). `⌥⌘R` summons a quick-input popover from anywhere.
- **First-run flow.** Six steps walk a new owner through robot
  reachability, LM Studio, permissions, the brain, a hello, and
  optional face enrolment.
- **Inspector drawer** with Activity, Memory, and Raw tabs — every
  motor command, tool call, transcript, and sidecar restart is
  visible in time order with full payloads.
- **Calm tech.** Designed to live next to you all day without
  catching your eye when idle.

### Architecture (the parts that earn their keep)

- **Sidecar contract.** Every external process — Python ML, robot mic,
  TTS engine, memory store — runs under one IPC convention
  (line-delimited JSON over stdin/stdout, supervised with restart and
  circuit breaker). `kill -9` recovery is automatic and tested.
- **Three independent loops** with their own cadences (10 Hz robot
  state, 50 Hz face-target, event-driven voice/brain). They never
  call each other directly — they signal through the `LogBus` actor.
- **Swift 6 strict concurrency** end-to-end. Actors, `@Observable`,
  `AsyncStream`. No `@unchecked Sendable` shortcuts.
- **Closed-set telemetry.** Every observable event is a case in
  `TelemetryEvent`. New event type = one place to add it. The
  dashboard, archive, and Logs view all read from one source.
- **Resilient under failure.** Robot offline → voice still works.
  LM Studio offline → Rocky tells you "can't reach my brain." A
  sidecar crash → supervisor restarts it within seconds with
  visible recovery in the UI.

---

## What's in this repository

- `Sources/` — Swift 6 package. Eight targets (`RockyKit`, `Telemetry`,
  `SidecarHost`, `RobotLink`, `RockyVision`, `Voice`, `Cognition`,
  `Memory`, `Perception`) plus the `Rocky` executable.
- `Tests/` — Swift Testing suite. 55 tests across 17 suites at last
  count, including integration tests that spawn echo + face-tracker
  sidecars to prove the sidecar contract end-to-end (`kill -9` recovery
  included).
- `Sidecars/` — Python sidecars under one IPC convention
  (line-delimited JSON over stdin/stdout, supervised lifecycle). One
  per shipped capability: `face-tracker`, `robot-mic`, `robot-camera`,
  `mlx-tts`, `mempalace`, plus an `echo` reference.
- `scripts/` — `build-app.sh` (assembles + signs `Rocky.app`),
  `run.sh` (build + open).
- `docs/` — an **Obsidian vault**. My thinking as it evolves while
  building with Rocky — not a polished documentation site. Open it in
  Obsidian (one-click vault import, the `[[wiki-links]]` and tags
  resolve cleanly) or just read it as Markdown. Start at
  [`docs/index.md`](docs/index.md).
- `CLAUDE.md` — instructions for Claude Code when working in this
  tree. Worth a read if you're contributing.

---

## Hardware

You need either of these to do anything interesting:

- **A Reachy Mini Wireless** robot, awake and on the same WiFi as
  your Mac. The daemon listens on `http://reachy-mini.local:8000`
  (mDNS); a manual IP works in `Settings → Brain` if mDNS is flaky.
- **An Apple Silicon Mac on macOS 15 (Sequoia) or later.** Tested on
  M2 / M3 / M4. Intel Macs are unsupported — MLX needs Apple Silicon,
  and the on-device Speech models prefer the Neural Engine.

You can run Rocky without a robot connected — the cockpit, the brain,
voice, and memory all work; tools that touch motion will return a
"robot offline" error to the LLM. Tools that don't (calendar, weather,
search, time, remember) work fully.

---

## Software prerequisites

In rough order of how soon you'll hit them:

1. **Xcode 16 / Swift 6 toolchain.** `xcode-select --install` (or
   Xcode from the App Store).
2. **uv** — `curl -LsSf https://astral.sh/uv/install.sh | sh`. Used by
   every sidecar's `setup.sh`. *(Required.)*
3. **LM Studio** — https://lmstudio.ai/. Install, launch, click the
   server icon to enable the OpenAI-compatible HTTP API on
   `http://localhost:1234/v1`. Then download a model — Rocky's
   default is `gemma-4-e4b-it-mlx`, which is small enough to run on
   16 GB Macs and supports tool-calling via the fenced-JSON fallback.
   For better tool fidelity, `qwen2.5-7b-instruct-mlx` or
   `qwen3.6-27b@4bit` (if you have the RAM) work natively.
4. **A signing identity (recommended).** The free Apple Development
   cert that Xcode auto-generates from an Apple ID is enough.
   `scripts/build-app.sh` picks it up automatically. Without one, the
   build falls back to ad-hoc signing — works, but every rebuild
   re-prompts for permissions. See
   [`docs/concepts/permissions-authority.md`](docs/concepts/permissions-authority.md).
5. **The `reachy_mini` Python SDK** is needed only for the
   `face-tracker`, `robot-mic`, and `robot-camera` sidecars. It's
   installed automatically by their `setup.sh`.

---

## Installation

```bash
git clone <this-repo> rocky
cd rocky
```

### Step 1 — Set up the sidecars

Each sidecar gets its own `uv venv` under
`~/Library/Application Support/Rocky/sidecars/<name>/.venv/`. Setup is
idempotent; re-run any time `pyproject.toml` changes.

```bash
# Synthetic-target test scaffold for development without a robot or
# camera. The real face tracker (Apple Vision) lives in Swift and
# does not need this sidecar — but the supervisor expects the venv
# to exist, so set it up once.
./Sidecars/face-tracker/setup.sh

# 4-mic ReSpeaker array via WebRTC. Default mic source on robot installs.
./Sidecars/robot-mic/setup.sh

# RGB camera over WebRTC. Frames are consumed by Apple Vision face
# detection in Sources/Perception/MacFaceTracker.swift.
./Sidecars/robot-camera/setup.sh

# Local memory store (mempalace). Recall is automatic, on by default.
./Sidecars/mempalace/setup.sh

# TTS — `say` backend (no deps, system voice).
./Sidecars/mlx-tts/setup.sh

# TTS — Chatterbox FP16 cloned voice (needs ~1.5 GB of MLX weights).
FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh
```

`AppServices` auto-detects venv presence and picks defaults: robot mic
when `robot-mic/.venv` exists, Chatterbox when `mlx-tts/.venv` has the
`mlx` extras. You can override either in `Settings → Voice`.

### Step 2 — Install LM Studio + a model

1. Install LM Studio from https://lmstudio.ai/.
2. Open it. Top right: server icon → toggle the local server on.
   Confirm it's listening on `http://localhost:1234/v1`.
3. In the model browser, search for `gemma-4-e4b-it-mlx` and click
   Download. Wait. Load it (the dropdown at the top of the chat tab).

Rocky probes LM Studio at startup and will tell you in the cockpit if
it can't reach the server or the model isn't loaded.

### Step 3 — (Optional) drop a voice reference for Chatterbox

If you set `FT_EXTRAS=mlx` for `mlx-tts`, Rocky can clone a voice from
a 5–10 second WAV / M4A at:

```
~/Library/Application Support/Rocky/voice/reference.wav
```

The recording should be the speaker speaking normally, in a quiet
room. Anything from a phone voice memo works. Without this, Chatterbox
falls back to a generic voice.

### Step 4 — Build the .app

```bash
./scripts/build-app.sh
open build/Rocky.app
```

You should see the cockpit. The first-run overlay walks you through:

1. Welcome.
2. Robot endpoint — verifies `reachy-mini.local:8000`.
3. Permissions — Microphone, Speech Recognition, Calendar, Location.
   Click each prompt; macOS pops a dialog; click Allow.
4. Brain — confirms LM Studio is reachable and a model is loaded.
5. Hello — say "Rocky, hello." Watch the conversation panel render
   the transcript and Rocky's reply.
6. Faces — defer or enrol from a photo.

If a step gets stuck, you can retry from `Help → Show first run`.

### Step 5 — Calibrate the microphone

`Settings → Voice → Sensitivity → Calibrate…` runs a 5-second flow
(2 s of room silence, 3 s of you speaking) and sets the VAD threshold
to a value that's safely above your room noise but well below your
voice. Recommended after any of:

- Moving the mic / robot to a different position on the desk.
- Switching `Settings → Voice → Source` between Mac mic and robot mic.
- Moving rooms.

You can also drag the slider manually; the live RMS readout helps you
see what threshold matches the room.

---

## Day-to-day commands

```bash
# Headless build (libraries + executable)
swift build

# Full test suite — 55 tests / 17 suites; integration tests spawn
# real echo + face-tracker sidecars
swift test

# Filter to one suite
swift test --filter "Sidecar host"
swift test --filter "WakeFilter"

# Build the proper macOS .app bundle (with Info.plist + signing).
# Use this — NOT `swift run` — because TCC permission prompts only
# fire reliably for a real bundled app with a stable signature.
./scripts/build-app.sh
open build/Rocky.app

# Build + open one-shot
./scripts/run.sh
```

For IDE indexing, open `Package.swift` directly in Xcode. Note: `⌘R` in
Xcode runs the raw SwiftPM debug binary — not the bundled .app — so
permissions and the SwiftUI window may behave unexpectedly. Always
launch via `build/Rocky.app` for real testing.

---

## Resetting state

Sometimes you want to start over. The relevant scopes:

```bash
# Reset every UserDefaults key (settings, persona, model, mic source,
# TTS backend, mic VAD threshold, brave key, persona migration, etc.)
defaults delete ai.amplified.Rocky

# Reset macOS permission grants — useful if Rocky says "denied" but
# System Settings shows the toggle on (debug-binary collision; see
# docs/concepts/permissions-authority.md).
tccutil reset Microphone           ai.amplified.Rocky
tccutil reset SpeechRecognition    ai.amplified.Rocky
tccutil reset Calendar             ai.amplified.Rocky

# Nuke a sidecar venv and force a fresh setup.sh
rm -rf "$HOME/Library/Application Support/Rocky/sidecars/<name>/.venv"

# Wipe stored memory (mempalace will recreate the store on next launch)
rm -rf "$HOME/Library/Application Support/Rocky/Memory"
```

---

## Troubleshooting

### "Rocky doesn't react when I say his name."

Likely the VAD threshold is too high (the live RMS sits below it during
your speech) or too low (room noise has it permanently latched).
Calibrate: `Settings → Voice → Calibrate…`.

If calibration also doesn't help, check:

- Is `Settings → Voice → Source` set to the source you expect?
  Switching requires toggling Listen off and on.
- For Mac mic: `Settings → Permissions` — is Microphone granted? Run
  `tccutil reset Microphone ai.amplified.Rocky` and re-grant if the
  state is confused.
- For robot mic: is the `robot-mic` venv present? Did the robot
  daemon report online? Check the StatusView Health rows.

### "Permissions are granted in System Settings but Rocky says denied."

This is the debug-binary collision. You probably ran `swift run` first,
granted against the SwiftPM binary, and now run the .app — different
CDHash, different TCC identity.

Fix:
```
tccutil reset Microphone        ai.amplified.Rocky
tccutil reset SpeechRecognition ai.amplified.Rocky
tccutil reset Calendar          ai.amplified.Rocky
./scripts/build-app.sh
open build/Rocky.app
```
Then click each prompt as it appears. See
[`docs/concepts/permissions-authority.md`](docs/concepts/permissions-authority.md).

### "TTS sounds robotic / wrong voice / says 'kuh-puh-huh'."

- Wrong voice: confirm `Settings → Voice → Engine` is `Chatterbox FP16`
  and `~/Library/Application Support/Rocky/voice/reference.wav`
  contains the voice you want.
- "Kuh-puh-huh" or symbol-spelling: that's an abbreviation that slipped
  past `cleanupForTTS`. File a bug with the exact text — the
  normalisation gate is in `Sources/Cognition/CognitionEngine.swift`.

### "The brain takes ages to reply."

- Check LM Studio's load. The model may be a heavier 4-bit quant than
  your hardware can serve at speed. Try `gemma-4-e4b-it-mlx`.
- LM Studio keeps the model loaded across requests — first reply is
  always slowest. Subsequent replies should be sub-second.

### "Robot is moving erratically."

Stop the robot (`Settings → Brain → Stop motion`), then check:

- Two Rocky instances running? Only one should be — the single-instance
  guard should refuse the second, but if you launched both
  `swift run` and the .app at once you'll see two control loops fighting.
- Is face tracking on at the same time as a recorded move?
  `pause_face_tracking` while the move runs.

### "Wake word triggers when Rocky speaks."

The echo gate stamps `ttsBusyUntil` *before* TTS begins, with a 1.5 s
tail. If TTS bleed still triggers wake, the tail may be too short for
your speaker volume. File a bug with the exact loop pattern.

---

## Architecture

The [`docs/`](docs/) folder is an Obsidian vault — a thinking-in-progress
journal of what I'm learning as I build with Rocky. It captures
decisions, design rationale, gotchas, and the wire-shape sources of
truth. Newer entries supersede older ones; check
[`docs/log.md`](docs/log.md) for the chronology.

Open it in Obsidian for the full experience (back-links, graph view,
tag search) or read individual files as plain Markdown. Best entry
points:

- [Architecture](docs/concepts/architecture.md) — daemon/SDK split,
  where code runs.
- [Rocky architecture](docs/concepts/rocky-architecture.md) — Rocky's
  internal layout, three loops, AppServices.
- [Sidecar convention](docs/concepts/sidecar-convention.md) — the IPC
  contract every Python process honours.
- [Voice / listen pipeline](docs/concepts/voice-pipeline.md) — mic
  through wake filter.
- [Tools registry](docs/concepts/tools-registry.md) — how the LLM gets
  things done.
- [Permissions authority](docs/concepts/permissions-authority.md) —
  TCC, signing, the debug-binary trap.
- [Cockpit design](docs/concepts/cockpit-design.md) — UI design
  contract.
- [Motion philosophy](docs/concepts/motion-philosophy.md) —
  `goto_target` for gestures, `set_target` in a control loop.
- [Safety limits](docs/concepts/safety-limits.md) — what the robot
  refuses, and why.

Architecture decisions live in [`docs/decisions/`](docs/decisions/).
The chronological build log is [`docs/log.md`](docs/log.md) — a good
place to scan when you want to know "why was this done this way?".

---

## Built on

Rocky is glue around a stack of other people's good work. The pieces
it depends on at runtime, with thanks:

### Robot platform

- [Reachy Mini Wireless](https://www.pollen-robotics.com/reachy-mini/)
  — Pollen Robotics. The robot itself, plus its on-board daemon.
- [`pollen-robotics/reachy_mini`](https://github.com/pollen-robotics/reachy_mini)
  — Python SDK used inside the `robot-mic`, `robot-camera`, and
  (planned) face-tracker sidecars to access WebRTC media streams.

### LLM runtime

- [LM Studio](https://lmstudio.ai/) — local OpenAI-compatible model
  server. Rocky targets its endpoint at `localhost:1234/v1`.
- [`ml-explore/mlx`](https://github.com/ml-explore/mlx) — Apple's
  array framework for Apple Silicon. Powers the MLX-quantised
  variants of every model below.

### Models (run inside LM Studio)

- [Gemma](https://huggingface.co/google) — Google. Rocky's default
  is `gemma-4-e4b-it-mlx`, small enough for 16 GB Macs.
- [Qwen](https://huggingface.co/Qwen) — Alibaba. Recommended when you
  have the RAM (Qwen 2.5 7B / 3.6 27B 4-bit) for stronger native
  tool-calling.

### Voice

- [`Blaizzy/mlx-audio`](https://github.com/Blaizzy/mlx-audio) — TTS /
  STT / STS on MLX. Rocky's `mlx-tts` sidecar uses it to load and
  run Chatterbox.
- [`resemble-ai/chatterbox`](https://github.com/resemble-ai/chatterbox)
  — Resemble AI's open-source voice-cloning TTS. Rocky's "Chatterbox
  FP16" engine.
- Apple's `SFSpeechRecognizer`, `AVAudioEngine`, and Vision frameworks
  for on-device STT, mic capture, and face detection (system, not
  external).

### Memory

- [`MemPalace/mempalace`](https://github.com/MemPalace/mempalace) —
  open-source AI memory store. Wrapped by the `mempalace` sidecar for
  recall + record around every LLM turn.

### Tools Rocky calls at runtime

- [Brave Search API](https://brave.com/search/api/) — backs the
  `search_web` tool. Bring your own subscription key.
- [Open-Meteo](https://open-meteo.com/) — backs `get_weather`. Free,
  no key, non-commercial use.

### Tooling

- [`astral-sh/uv`](https://github.com/astral-sh/uv) — Astral's Python
  package manager. Every sidecar's `setup.sh` uses it to create a
  pinned venv.

If your project ends up on this list and you'd rather not be — open
an issue and I'll remove it.

---

## Contributing

If you're contributing — please read `CLAUDE.md` first. It's the
collaboration contract, not just an AI prompt: it captures the safety
rules, conventions, and non-negotiables that make this code good to
work with.

A few load-bearing ones:

- **Robot safety: small changes only.** Never stack motion-control
  changes. One tweak per iteration, verify calm, then next.
- **Don't band-aid.** After two failed tweaks in the same direction,
  stop and name the real problem. Revert if needed.
- **Sidecar contract is the invariant.** External processes always
  run through `SidecarHost`. No ad-hoc `Process.run`.
- **Telemetry is closed-set.** Add a case to `TelemetryEvent` rather
  than a new event taxonomy.
- **Tools live in the registry.** Don't sidestep `ToolRegistry` to
  give the LLM a capability.
- **Update the wiki.** Anything you learn from a source, the user, or
  your own work goes into `docs/` per `docs/WIKI.md`. Add an entry
  to `docs/log.md` for each non-trivial session.

---

## License

[MIT](LICENSE) — do anything you like with the code, just keep the
copyright notice and don't sue me when something breaks.
