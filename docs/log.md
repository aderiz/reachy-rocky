# Log

Append-only chronological record. Each entry: `## [YYYY-MM-DD] <op> | <subject>`. Run `grep "^## \[" log.md | tail -20` for the recent timeline.

## [2026-05-12] docs | ADR 0006 — on-bot media relay (backfill)

The biggest architectural decision on the project — replace WebRTC with a bot-side Reachy Mini App that serves audio + video over plain WebSocket — was implemented on 2026-05-11 (commit `3649b93`) but never written up as an ADR. Captured retroactively as `decisions/0006-on-bot-media-relay.md` with the full context (WebRTC failure modes seen on WiFi, alternatives considered, trade-offs, consequences, implementation references) so future readers don't need to reconstruct the reasoning from commit messages.

Also documents the relay's role as the catch-all conduit for state the daemon doesn't expose — first the `/battery` endpoint (per the Dynamixel reg-144 workaround), but generalisable.

`docs/index.md` updated with the 0006 entry.

## [2026-05-12] docs | Backfill ADR 0004 (Hermes Agent) + flesh out OnBot relay README

The wiki catalog had a hole between ADRs 0003 and 0005 because ADR 0004 (Hermes Agent integration) was authored on the `hermes-agent` branch and never merged. Cherry-picked the three artifacts onto `main`:

- `docs/decisions/0004-hermes-agent-integration.md` — the decision itself, status `accepted` with an implementation-status note pointing at the `hermes-agent` branch where the work lives.
- `docs/concepts/hermes-agent.md` — concept doc covering Hermes' role as Rocky's optional advanced cognition backend.
- `docs/workflows/integrate-hermes-agent.md` — implementation plan referenced by the ADR.

`docs/index.md` lists all three; concepts and decisions sections updated.

Separately: `OnBot/rocky_media_relay/README.md` was missing every battery / camera-sleep / autostart addition shipped on the `listening-rework` branch. Rewrote to include the `/battery` endpoint + schema + empirical thresholds, the Dynamixel reg-144 workaround story, the camera-sleep behaviour driven by `video_clients == 0`, and the Mac-side `ensureRelayAppRunning` autostart.

## [2026-05-12] docs | Backfill — on-bot relay extras + power monitoring + portrait + antenna constraint

The wiki had drifted significantly behind the `main` and `listening-rework` branches. This pass closes the gap.

**`docs/concepts/on-bot-media-relay.md`** — added an HTTP-surface table (covering `GET /battery`, the new `/health` battery field, control endpoints), a "Camera sleep" section explaining how `video_clients == 0` gates JPEG encoding on the bot (and how `sleepRobot` triggers it), and an "Auto-start on Mac launch" section documenting `AppServices.ensureRelayAppRunning()`. Previously the doc covered only the WS streams and the WebRTC trade-offs.

**`docs/reference/power-monitoring.md`** — new page covering the **Dynamixel reg-144 workaround** for supply voltage. Documents: why the Wireless has no software-readable battery state (BMS is purely protective, no kernel power-supply driver, no daemon API), what GPIO 23 actually is (shutdown push-button, not charger-detect), the daemon's existing `voltage_ok` reader, the empirical voltage thresholds (DC 7.30 V vs battery 6.40–6.50 V), the LiFePO4 voltage→SOC anchors, the relay's `/battery` schema, the Mac-side BatteryService + BatteryChip rendering, why we route through the relay instead of polling motors directly.

**`docs/reference/hardware.md`** — Power section now notes "no fuel-gauge IC" + the motor-voltage workaround, with a pointer to power-monitoring.md.

**`docs/reference/motors.md`** — added two sections: "Antennas resonate at vertical — never command 0 rad" (the ±0.1745 rad rest constraint, with the `INIT_ANTENNAS_JOINT_POSITIONS` citation from Pollen's daemon source) and "Reading supply voltage from motors" pointing at the power-monitoring page.

**`docs/concepts/portrait.md`** — new page documenting the portrait composition: avatar + senses chip + power chip + name plate + wake toggle, light/dark backdrop adaptation (`backdrop(for: ColorScheme)`), `WakeSleepSwitch` conventions (green-when-awake, thumb-right = on, ⏎ toggles, sun/moon glyphs), state-source bindings for each element.

**`docs/index.md`** — added portrait + power-monitoring entries; updated motors summary.

## [2026-05-12] code | Listening rework — `listening-rework` branch

The single-signal "did VAD see speech?" dispatch gate was producing constant unwanted turns: Whisper hallucinations ("thank you", "subtitles by Amara"), background TV, other people's conversations. Auto-extending conversation window meant one bad hallucination locked Rocky in "engaged" mode for an hour. Face tracker autonomous idle pan made the head wander whenever nobody was directly in frame. Wake-on-name had no gate at all — a Whisper hallucination of "rocky" on silence woke the bot from sleep.

**New `AddressFilter` actor** (`Sources/Voice/AddressFilter.swift`) sits between STT and the brain, fusing all available signals: segment peak / mean RMS, DoA + `is_speech` from the on-bot mic array, face age, STT confidence, junk-phrase deny-list, wake-reason, TTS state, mic source. Strict ruleset: wake-name still wins, **but only if `segmentPeakRMS ≥ rmsFloor`** so silence-driven hallucinations can't sneak through. For non-wake transcripts, all of `loud + on-axis + engaged` must hold. `engaged` = face visible ≤ 3 s OR DoA on-axis with `is_speech: true` OR transcript begins with a verb prefix. Strict mode means "drop on ambiguity." 13 table-driven unit tests.

**WakeFilter rework.** Window default 60 s → 20 s. `.withinWindow` no longer auto-extends; new `extendOnEngaged()` is called by `AppServices.handleVoice` only when AddressFilter accepts with real engagement evidence. So hallucinations can't perpetually re-extend.

**Calibration adds a 4th phase + motors-under-load.** `MicCalibrationView` was three auto-flowing phases; now it's four with the speech phases user-gated. The Rocky phase drives a smooth 50 Hz parametric Lissajous head sweep (yaw ~16°, pitch ~6°, coprime periods 3.7 s / 2.3 s) via direct `setTarget` POSTs while audio captures. Face tracking is **triple-suppressed** for the duration (`transitioningUntil` + `targetStreamer.setPrimaryMoveActive(true)` + `setFaceTrackingEnabled(false)`) so nothing else can steal motor attention. The new "Address Rocky" phase captures direct-address RMS + DoA (robot mic) and computes the four AddressFilter values. **Critical math fix**: VAD threshold and AddressFilter noise ceiling both use **room P99 only**, not motors-under-load. Motors are idle when Rocky is actually listening to the user; including motion-loaded samples in the ceiling made normal speech unattainable. Diagnostic LogBus event fires at end-of-compute so the user can see exactly what calibration produced. The flow uses Mac-side `services.wakeRobot()` / `sleepRobot()` (not raw daemon endpoints) so transitions land at home pose.

**Whisper hallucination mitigation** (Sidecars/mlx-stt): `initial_prompt="A short conversation between a person and a robot named Rocky."` biases the language prior away from YouTube-credit hallucinations. Temperature fallback ladder `(0.0, 0.2, …, 1.0)` retries on `compression_ratio_threshold=1.8`. `no_speech_threshold=0.7`. Confidence-gated phrase deny-list drops boilerplate only when segment `no_speech_prob ≥ 0.4` or `avg_logprob ≤ -0.8` — real "thank you" said clearly passes. Plus the existing n-gram repetition collapse.

**Face tracker behavioural fixes.** `decayIfIdle` (autonomous Lissajous pan when face out of frame) is now opt-in via `SettingsStore.faceTrackerIdleSearchEnabled`, default `false`. `MacFaceTracker.setSleeping(_:)` called from `sleepRobot` / `wakeRobot` — frame ingestion is skipped while asleep (saves ~10 ms Vision pass per frame, prevents EMA drift).

**Antenna anti-vibration**. Antenna motors mechanically vibrate at exactly 0 rad (vertical), per a comment in Pollen's `reachy_mini.py` (`INIT_ANTENNAS_JOINT_POSITIONS = [-0.1745, 0.1745]  # ~10° offset to reduce shaking at vertical`). Two prior fixes (amplitude/rate, quantisation) failed because the noise is downstream of the setpoint. Now both antennas rest at the same ±0.1745 rad offset; twitches are deltas relative to rest.

**Other small fixes shipped on this branch.** Camera feed pauses on sleep (no JPEG encoding on the bot when no `/ws/video` subscriber). On-bot relay exposes `/battery` reading supply voltage via Dynamixel motor register 144 through the daemon's raw-packet WS (no fuel gauge IC on the hardware — voltage is the discriminator). Power chip on the portrait with iOS-style pill glyph. Portrait backdrop adapts to system colour scheme. Wake/sleep toggle restyled to iOS green-when-awake convention (thumb-right = on).

Wiki: `docs/concepts/voice-pipeline.md` rewritten; new `docs/concepts/address-filter.md`; CLAUDE.md updated. 76 tests pass.

Branch: `listening-rework`. Will land into main when stable.

## [2026-05-11] code | On-bot media relay — rearchitect on `on-bot-media-relay` branch

Replaced the Mac-side WebRTC media path with a bot-side Reachy Mini App + plain WebSocket. The motivation came from days of WebRTC instability on WiFi: signalling drops, DTLS errors, sidecar respawn loops, silent / zero PCM, VAD over-segmentation. The official remote-media path is WebRTC; the v0.3 path uses the Apps system instead.

**`OnBot/rocky_media_relay/`** — new Reachy Mini App scaffolded via `reachy-mini-app-assistant create`. Subclasses `ReachyMiniApp`. Inside `run()` it polls `mini.media.get_audio_sample()` / `get_frame()` / `get_DoA()` from the SDK's LOCAL backend (IPC + direct GStreamer, no encode/decode hop), JSON-line-encodes each, and fans them out to subscribers via WebSockets mounted on `self.settings_app` at `/ws/audio` and `/ws/video`. Per-client queues are bounded (200 messages) and drop-oldest under pressure. `POST /control/{start,stop}_recording` toggles audio capture; `GET /health` returns counters. Passes `reachy-mini-app-assistant check`'s structural + install probes.

**`Sidecars/robot-mic` / `Sidecars/robot-camera` rewritten as WS subscribers.** Each runs its own asyncio loop on a background thread with exponential-ish reconnect (1 → 2 → 5 → 10 s). Translates the relay's envelope into the existing SidecarHost stdout shape (`audio` / `doa` / `frame`) — Swift adapters unchanged. Dropped the heavy `reachy-mini` SDK dep from both Mac sidecars; pyprojects now pull only `websockets` (+ `numpy` for the mic's peak diagnostics).

**Swift manifests** updated to set `ROCKY_RELAY_PORT=8042` (the app's `custom_app_url`) and drop `ROCKY_ROBOT_PORT`/camera tuning vars (camera FPS / quality / width now live on the bot side).

**Trade-offs.** Plain WS over LAN has none of WebRTC's encryption / NAT / codec-renegotiation features — Rocky doesn't need them. The bot's "only one app at a time" constraint applies: `rocky_media_relay` consumes the single app slot. Lower latency (no encode/decode), higher stability (TCP), simpler debugging.

**Wiki.** New `docs/concepts/on-bot-media-relay.md`, new `docs/workflows/deploy-media-relay.md`, index updated. Both Mac sidecars came up clean and entered their reconnect loop with no bot relay running — the supervisor never sees them as failed because they emit `ready` before the network attempt.

Branch: `on-bot-media-relay`. Per the rearchitect-branch convention, the WebRTC sidecar revisions live on `rearchitect` and are NOT carried forward when this branch lands.

## [2026-05-11] code | Brain + TTS + vision: end-to-end fixes for the chat/audio divergence

Closed three real defects and one missing feature spotted while testing the v0.2 stack on the `rearchitect` branch.

**Brain runner — streaming-safe tool-call extraction.** Previously the runner streamed raw `<|tool_call>...<tool_call|>` markers to the UI then re-parsed them post-stream, which (a) leaked the markers into the chat bubble and (b) double-emitted tool_call events (one from the post-stream parse, one from the model retrying after the first call errored). New `StreamFilter` in `Sidecars/brain/rocky_brain/runner.py` suppresses bytes between the markers token-by-token, and emits each captured block exactly once via `parse_tool_call_block` (mlx-vlm's `gemma4` parser, singular form). The post-stream re-extract is gone; a fenced-JSON fallback only runs when the streaming filter captured nothing.

**CognitionEngine — end turn after `say`.** When the model called `say`, we looped back to the brain for another round and the model would chatter with a *different* sentence in plain text — that follow-up text became the assistant bubble, so chat and audio diverged. After `say` fires, the turn ends. The semantic contract is "say IS the response."

**AppServices — mirror `say` text into the chat bubble.** When the `say` tool returns OK, drainBrainStream now appends a fresh assistant bubble with the spoken text (`extractSayText` reads it from the dispatched args). The bubble matches the audio rather than rendering whatever the model emitted as plain text in a later round.

**TTS — Qwen3-TTS-12Hz-1.7B-Base via mlx-audio 0.4.3.** Three composite fixes:
1. Switched model to `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` (native MLX BF16). `CustomVoice` variant doesn't support ICL cloning; `Base` does.
2. Call `Model.generate(text=…, ref_audio=…, ref_text=…, stream=True, streaming_interval=0.32)` directly instead of going through `mlx_audio.tts.generate.generate_audio` — that helper consumes the iterator internally for playback / save side effects, so the per-chunk PCM never reaches the caller. `streaming_interval=0.32` is the canonical low-latency value from the mlx-audio v0.4.3 Qwen3-TTS README.
3. Auto-resolve `ref_audio` + `ref_text` from `~/Library/Application Support/Rocky/voice/sample.{wav,txt}` (fallback to `reference.{wav,txt}`). Long references degrade ICL — operationally we trim to 3–10 s; 22 s was producing ~2× too-long output.

**TTS — `StreamingTTS.playToRobot(chunks:media:filename:)`.** New method that accumulates PCM chunks from the Qwen3-TTS streaming generator, wraps them in a WAV, uploads to the daemon, and calls `play_sound`. Audio now plays only through the robot speaker; the Mac stays silent. `isSpeaking` still flips on the first PCM chunk (echo gate engages as soon as synthesis starts), then flips back off after `durationS + sttPostRollS`. `RobotTTS.speakStreaming` was rewired to call `playToRobot` instead of the `AVAudioEngine`-backed Mac path. The Mac-local `play(chunks:)` method survives but has no callers.

**Persona v6 — VISION section with worked examples.** Wiring for the camera→brain feed (RobotCameraService → lastCameraFrame → CognitionEngine.imageProvider → MLXVLMBrain.image_b64) was already in place and verified to work with Gemma 4 26B-A4B (which IS a vision model — early hunch that it was text-only was wrong; it has `vision_config` + `image_token_id`). The bottleneck was the persona, which had zero vision examples — Rocky's strict voice rules made the model default to "Rocky not know" on visual questions. New VISION block lists when to look + five examples (mug, kitchen, shirt, book, empty/dark frame). `currentPersonaVersion` bumped 5 → 6 so the migration overwrites stale personas on next launch.

**Cockpit — toolbar toggles for vision + face tracking.** Two new buttons in `RootView.swift` next to mic + speaker mute. `eye.fill` / `eye.slash.fill` gates whether the camera frame is forwarded to the brain (camera sidecar keeps running for face tracker + Vision card); `face.smiling.inverse` / `face.dashed` toggles the existing `setFaceTrackingEnabled` from a place users actually look. New `visionEnabled` observable on AppServices; `imageProvider` returns nil when off.

**Status panel — "Think" reflects active backend.** Previously the LM Studio row always showed, even when `brainBackend == "mlx-vlm"`, so users saw a confusing "LM Studio offline" card next to a working MLX brain. New `brainRow` picks between `mlxBrainRow` (sidecar state + model short name) and `llmRow` based on `settings.brainBackend`; in `auto` mode it resolves to whichever is currently ready. Both the capability tile and the section content read from the same row.

Files touched:

- `Sidecars/brain/rocky_brain/runner.py` — StreamFilter, parse_tool_call_block, get_tool_markers, fallback_extract_tool_calls; streaming loop suppresses markers and no longer double-extracts.
- `Sidecars/mlx-tts/rocky_tts/qwen3_tts_backend.py` — Base model, ICL cloning, streaming_interval=0.32, auto ref_text resolution from sample.txt.
- `Sidecars/mlx-tts/manifest.json` — default ROCKY_TTS_BACKEND=qwen3-tts, ROCKY_TTS_QWEN3_MODEL=mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16.
- `Sources/Cognition/CognitionEngine.swift` — end-turn-after-say.
- `Sources/Rocky/AppServices.swift` — pendingSayText buffer + mirror, visionEnabled flag + setVisionEnabled, extractSayText, imageProvider gated by visionEnabled.
- `Sources/Rocky/SettingsStore.swift` — persona v6 VISION section.
- `Sources/Rocky/RootView.swift` — vision + face tracking toolbar buttons.
- `Sources/Rocky/StatusView.swift` — brainRow / mlxBrainRow / llmRow, capability + section wiring.
- `Sources/Voice/StreamingTTS.swift` — playToRobot, wrapPCMInWAV; imports RobotLink.
- `Sources/Voice/RobotTTS.swift` — speakStreaming routes via playToRobot.

End-to-end verification on the `mlx-community/Qwen3-VL-4B-Instruct-4bit` brain + `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` TTS combo:

- Vision: shown a yellow circle (PIL test JPEG) → model said "yellow circle in the center" (Qwen3-VL) and "I see a yellow circle in the center of the image" (Gemma 4 26B-A4B).
- TTS streaming: first chunk at ~2.9 s (ICL prefill floor), 6.96 s of audio for ~7 s of expected speech with a 6 s reference — correct pacing. 13 s outputs from a 22 s reference confirmed the long-reference degradation.
- Tool-call extraction: `<|tool_call>call:search_web{query:<|"|>what is Claude Code<|"|>}<tool_call|>` → exactly one tool_call event, no marker leak in emitted deltas.

## [2026-05-09] doc | Correction — face tracking is Apple Vision, not SAM 3.1

The README and several docs claimed face tracking ran on SAM 3.1 via
the `face-tracker` Python sidecar. That was the M3 *plan*; it was never
implemented (see `Sidecars/face-tracker/rocky_face_tracker/runner.py`
lines 92-94 — `sam` mode falls through to the synthetic detector with
a `"non-synthetic detector not yet implemented"` log line).

What actually ships:

- Real face tracking is Swift-side in
  `Sources/Perception/MacFaceTracker.swift`. It pulls JPEG frames from
  the `robot-camera` sidecar, runs Apple Vision's
  `VNDetectFaceRectanglesRequest`, picks the largest bbox, converts to
  world-frame yaw/pitch using the camera's 65°/39° FOV, smooths with
  EMA + a critically-damped 50 Hz controller, and pushes the smoothed
  pose into `TargetStreamer`.
- The Python `face-tracker` sidecar is now correctly described as a
  **synthetic-target test scaffold** (Lissajous pattern) used during
  development without a robot or camera. It's still wired through
  `FaceTrackerService` → `FaceTargetBridge` for that purpose, but the
  shipped path is `robot-camera` → `MacFaceTracker` → `TargetStreamer`.
- The `[sam]` extras in `pyproject.toml` and the `ROCKY_FT_MODE=sam`
  manifest knob are kept (so a future ML detector can slot in via the
  same sidecar without churn) but are now flagged as unimplemented in
  every doc that mentioned them.

Files corrected:

- `README.md` — Vision feature bullet, sidecar setup commands,
  robot-camera comment.
- `CLAUDE.md` — face-tracker target-loop description, sidecar setup
  block, validated-implementation pointer.
- `docs/index.md` — face-tracker sidecar entry; robot-camera entry.
- `docs/concepts/rocky-architecture.md` — block diagram (added
  `Perception/MacFaceTracker`, expanded sidecar list); face-tracker
  loop description.
- `docs/concepts/sidecar-convention.md` — sidecars-in-the-tree table.
- `docs/decisions/0002-rocky-app.md` — context paragraph on the
  project memory that drove the decision (plan said SAM,
  implementation chose Apple Vision; the design constraints held).
- `docs/decisions/0003-sidecar-convention.md` — context paragraph and
  the `mlx-swift`-rejected alternative footnote.
- `Sidecars/face-tracker/pyproject.toml` — package description.

## [2026-05-08] doc | Top-level README + wiki catch-up

The wiki had drifted out of date; the last log entry before this was
2026-05-07 (cockpit design), but several substantial surfaces shipped
between then and now without docs. Catch-up pass:

- `README.md` (new, repo root) — what Rocky is, hardware/software
  prerequisites, install + first-run + day-to-day commands, the LM
  Studio / sidecar / voice-reference setup, troubleshooting, pointers
  into `docs/`.
- `docs/concepts/voice-pipeline.md` (new) — the listen path from mic
  → ring buffer → VAD → STT → wake filter → cognition. Includes the
  pre-roll buffer, queued-segment logic, mic-source switch, and the
  calibration model now exposed via Settings → Voice → Calibrate.
- `docs/concepts/tools-registry.md` (new) — schema/handler shape,
  dispatch path including the fenced-JSON fallback for Gemma, and an
  inventory of the shipped tool surface.
- `docs/concepts/permissions-authority.md` (new) — single-source-of-
  truth model, the 5-state enum (granted/limited/denied/notDetermined/
  restricted), the "permission against the debug binary" pitfall and
  the signing flow that fixes it.
- `docs/index.md` — added the three new concept pages, removed the
  stale "dashboard fills in M3+" stub.

What had landed since 2026-05-07 and was not yet documented:

- **Cockpit waves**. `CockpitView` + `PortraitView` + `MomentStrip` +
  `ConversationView` replaced the old card stack. `Inspector*` is the
  drawer (Activity/Memory tabs).
- **Voice loop end-to-end**. `MicService` / `RobotMicService` →
  `AudioRingBuffer` (drop-newest under saturation) → `EnergyVAD` (live-
  tunable threshold) → `AppleSpeechSTT` (with first-launch retry for
  locale-data race) → `WakeFilter` → `VoiceCoordinator`.
- **Microphone calibration**. New Settings → Voice → "Sensitivity"
  section with manual slider + guided 2-phase calibration sheet
  (`MicCalibrationView`). Persists `micVADThreshold` in UserDefaults;
  applied live to the running VAD via `voice.setVADThreshold(_)`.
- **Tools registry — full set**. `look_at`, `set_motor_mode`,
  `wake_up`, `go_to_sleep`, `stop_motion`, `play_emotion`, `express`,
  `pause_face_tracking`, `resume_face_tracking`, `say`, `stop_speaking`,
  `get_state`, plus `Sources/Rocky/Tools/`: `get_current_time`,
  `read_calendar`, `get_weather`, `search_web`, `remember`. Each tool
  has its own static `register(in:)` entry point.
- **Cognition resilience**. `CognitionEngine.extractFencedToolCalls`
  recovers Gemma's markdown-wrapped invocations; `cleanupForTTS`
  strips quotes / template tokens / abbreviations before TTS so the
  spoken output sounds natural.
- **Permissions authority**. `Sources/Rocky/Permissions/
  PermissionsAuthority.swift` is the single source of truth for mic /
  speech / calendar / location, with the 5-state enum and per-process
  cache pitfall handled via `requestAuthorization`.
- **Stewart-platform 3D avatar**. `RockyAvatar` + `StewartIK` (WASM
  via JavaScriptCore) — head pose drives an inverse-kinematics linkage
  in the portrait. `wasm-bindgen Vec<f64>` consume-by-move convention
  documented in source.
- **Single-instance guard + clean shutdown**. `RockyApp.init` enforces
  one running instance; `applicationShouldTerminate` plays
  `goToSleep` instead of an abrupt motor disable.
- **Memory sidecar**. `Sources/Memory/MemoryService.swift` wraps the
  `mempalace` sidecar; recall + record stitched into the LLM turn loop.
- **Robot-camera + robot-mic sidecars**. WebRTC over the `reachy_mini`
  SDK with three-tier (mic) and two-tier (camera) recovery. Mutex
  around the shared media handle so the two sidecars don't tear each
  other's session down.
- **Build/sign flow**. `scripts/build-app.sh` prefers Apple Development /
  Developer ID over ad-hoc, intentionally drops `--options runtime`
  (hardened runtime + ad-hoc + no entitlements silently refused
  Calendar TCC on Sequoia).

The CLAUDE.md rule — "Anything you learn from a source, the user, or
your own work goes there per `docs/WIKI.md`" — applies going forward,
including a `log.md` entry per non-trivial session.

## [2026-05-07] doc | Cockpit design — UI design contract

A HIG-grounded design pass for Rocky's user-facing surface, after multiple
rejected directions (engineer NOC, virtual-employee profile,
menu-bar-first, ASCII-box pseudo-design). Authored via the
`swift-ui-design` specialist; refined to elevate the menu bar as the
**persistent** surface (Rocky is active when the window is closed).

The thesis: the window has a stage (portrait + conversation), a margin
(moment feed strip), a drawer (`.inspector` with Health / Activity /
Memory / Motion / Vision / Raw tabs), and a real `.toolbar` (Wake/Sleep,
Mic, Voice, health glance, inspector toggle, Settings). Settings becomes
a separate `Settings { TabView }` scene. The menu bar gets a full
popover with presence + last 3 moments + last exchange + ask Rocky input
+ quick controls; `⌥⌘R` summons it from anywhere.

Six implementation waves, each independently shippable; nothing in the
existing UI is deleted, only relocated.

- `docs/concepts/cockpit-design.md` — the full design.
- `docs/index.md` — entry added.
- Branch `cockpit-wave1` off `cockpit-centre` is where the work happens.

## [2026-05-05] code | Rocky M1 — workspace + foundational packages

Plan approved (`/Users/amplifiedai/.claude/plans/i-d-like-this-to-swirling-octopus.md`). M1 first-pass scaffold landed:

- `Package.swift` defines: `Rocky` (executable), `RockyKit`, `Telemetry`, `SidecarHost`, `RobotLink` (libraries) + 3 test targets. Swift 6 mode, `.macOS(.v15)`.
- `RockyKit`: `Angle`/`Length` units, `HeadPose` (16-element row-major SE(3)), `Antennas`, `MotorMode`, `SafetyLimits`, `RobotState`/`MotionTarget` codecs that map the daemon's wire shape (`head` as flat 16, `antennas` as `[right, left]`).
- `Telemetry`: `LogBus` actor (multicast `AsyncStream` subscription) and the closed `TelemetryEvent` taxonomy from plan §4.6.
- `SidecarHost` skeleton: `SidecarManifest` (JSON, `{venv}`/`{sidecar_dir}` placeholders), `Sidecar` protocol, `SidecarState`/`SidecarError`, `JSONLineCodec` (handles `response` / `error` / `stream` / `stream_end` / `event` / `log` envelopes; partial-line buffering), `SidecarSupervisor` registry. Real `SidecarRuntime` (Process/pipes/restart loop) lands in M2.
- `RobotLink`: `RobotLinkClient` actor (REST: `daemon/status`, `state/full`, `move/set_target`, `move/goto`, `move/stop`, `move/play/{wake_up,goto_sleep}`, `motors/set_mode/{mode}`); `TargetStreamer` actor (50 Hz tick, single producer/single consumer, pauses while `is_move_running`).
- `Rocky` app target: SwiftUI `WindowGroup` + `MenuBarExtra` shell, `AppServices @Observable`, placeholder dashboard / sidebar / hero card / connection badge.
- 12 Swift Testing tests across pose math, safety clamps, daemon-state decoding, endpoint URL composition, and JSON-line codec round-trips. All green.

Open M1 work: live `/openapi.json` validation against the actual robot, `HealthChecker` periodic poll, WebSocket state subscriber, motion-card visualization. Will land in subsequent commits before moving to M2.

## [2026-05-05] code | Rocky M2 — SidecarHost end-to-end

Implemented the user-mandated Sidecar contract end-to-end:

- `SidecarRuntime` actor: spawns a `Process`, owns three pipes, dispatches stdout envelopes through `JSONLineCodec`, drains stderr as logs, correlates `id`-keyed responses, supports stream methods, applies per-method timeouts via `withThrowingTaskGroup`, surfaces unsolicited events through an `AsyncStream`.
- `SidecarSupervisor`: registers a manifest as a runtime, watches each runtime's events stream, detects `.failing` and applies `restartPolicy` with per-minute circuit breaker (`restart_max_per_minute`).
- `FirstRunSetup`: idempotent installer that runs `setup.sh` only when `.venv/bin/python` is missing.
- `Sidecars/echo/`: stdlib-only Python proof-of-contract sidecar (echo, add, slow, fail, stream_count, crash). Manifest pins `/usr/bin/python3` so tests don't need a venv build.
- `EchoSidecarIntegrationTests` (6 tests): basic round-trip, concurrent requests, error envelopes, stream lifecycle, slow-method timeout, **supervisor-restarts-after-crash** (kills the process via `sys.exit(7)`, asserts the supervisor brings it back to `.ready` within 3s and a follow-up `echo` succeeds).

Total tests: 18/18 green. The supervisor crash-recovery test runs in ~0.4s end-to-end on M-series.

The Sidecar contract is now real and reusable. Subsequent sidecars (face-tracker M3, mlx-tts M5) drop in as a directory + a Swift adapter layer.

Tried `curl http://reachy-mini.local:8000/openapi.json` — robot not reachable (mDNS timeout). Live REST validation deferred until robot is on. Continuing with M3 in the meantime.

## [2026-05-05] code | Rocky M3a — face tracker (Python sidecar + Vision adapter, synthetic mode)

The validated face-tracker design (memory: `project_face_tracker_design.md`) reborn under the Sidecar contract. State-driven, world-frame target, decoupled detection rate from motion smoothness — **no regression to per-frame P-control**.

Python (`Sidecars/face-tracker/`):

- `geometry.py` — `CameraIntrinsics(hfov=65, vfov=39)`; `normalized_bbox_center` + `angle_from_pixel`. Sign convention preserved: face on the LEFT (un<0) → +yaw (head turns LEFT), face on BOTTOM (vn>0) → +pitch (head DOWN).
- `filters.py` — `EMA(alpha=0.5)` and `CriticalDamper(omega=3 rad/s)` second-order semi-implicit Euler.
- `controller.py` — `FaceTrackerController` ingests `Detection` events, EMA-smooths the world-frame target (current commanded yaw/pitch + camera-frame offset), 50 Hz tick advances dampers; idle decay toward (0,0) after 1.5 s of no detections.
- `detector_synthetic.py` — Lissajous-traced "face" with periodic dropout windows so we exercise decay-to-home offline.
- `runner.py` — JSON-line entry point. Two threads: detector ~10 Hz emits `detection` events, command 50 Hz emits `target` events. Methods: `set_enabled`, `set_prompt`, `update_commanded_pose`, `health`, `shutdown`. Real SAM 3.1 mode (M3b) is stubbed to synthetic for now.
- Sanity-checked the Python math directly: damper converges to 0.98 of target after 2 s, controller emits +yaw for face-on-left, sign conventions hold.

Swift (`Sources/Vision/`):

- `FaceTrackerService` actor — owns the sidecar, parses `target` and `detection` events, exposes `AsyncStream<Target>` and `AsyncStream<Detection>`. Forwards `setEnabled`/`setPrompt`/`updateCommandedPose` to the sidecar.
- `FaceTargetBridge` actor — turns `Target` (yaw/pitch radians) into `MotionTarget(head: HeadPose)` and pushes into `TargetStreamer`. Pre-clamps to safety limits. Has a `setSuppressed(_)` knob so primary recorded moves win.

Tests (5 new, 23/23 total):

- `FaceTrackerSidecarIntegrationTests` (3): ready+targets at 50 Hz, `set_enabled false` round-trip, `health` round-trip.
- `VisionTests/FaceTrackerServiceTests` (2): the typed adapter bridges both streams; control methods succeed.

M3b (real SAM 3.1 + Reachy SDK camera) opens when the user is at the robot.

## [2026-05-05] code | Live daemon validation + wire-shape refactor

Robot online at 192.168.1.173 (mDNS resolves now). Captured the live OpenAPI schema (79 endpoints, daemon v1.7.1, control loop 49.6 Hz / 20ms period). Created `sources/daemon-openapi-1.7.1.md` documenting deltas vs. our model. Major corrections:

- `/api/move/set_target` body uses `FullBodyTarget` with `target_` **prefixed** keys (`target_head_pose`, `target_antennas`, `target_body_yaw`). Head pose is XYZ+RPY by default, not a flat 16-element matrix. Matrix form is `{"m": [16 numbers]}` if used.
- `/api/move/goto` keys are **bare** (`head_pose`, `antennas`, `body_yaw`, `duration`, `interpolation`).
- `/api/state/full` returns `control_mode` (not `motor_mode`), `head_pose` (RPY object), `antennas_position` (not `antennas`), no `is_move_running` — derive from `/api/move/running` being non-empty.
- `WS /api/state/ws/full` exists and emits ~10 Hz; not advertised in OpenAPI.

Refactored to match the live wire:

- `RockyKit/RPYPose` added.
- `RockyKit/RobotState` switched to live shape (RPY pose, `control_mode`, `antennas_position`, optional `head_joints`/`passive_joints`/`doa`/`timestamp`).
- `RockyKit/MotionTarget` now serializes as `FullBodyTarget` with `target_*` keys.
- `RobotLink/RobotLinkClient.goto` rewritten with explicit `head_pose: RPYPose?`/`antennas`/`body_yaw`/`duration`/`interpolation`.
- `RobotLink/StateSubscriber` actor: WebSocket `/api/state/ws/full` with backoff reconnect; emits `RobotState` AsyncStream and publishes `motorState` telemetry events.
- `Vision/FaceTargetBridge` now produces `RPYPose` targets (was `HeadPose` matrix).
- `Rocky/MotionCard` added: live RPY bars (yaw/pitch/roll vs safety limits), antennas R/L, body yaw arc, motor-mode pill, frame-count pill.
- `AppServices` starts the StateSubscriber on launch and mirrors `lastRobotState` + `stateUpdateCount` on the main actor for SwiftUI consumption.

Live smoke test: posted `target_head_pose: {yaw: 0.0873}` (5°) → daemon returned `{"status":"ok"}` and the head moved (yaw climbed from baseline ~0.012 toward +0.041 in 700 ms before returning to 0). Wire format end-to-end confirmed.

Tests: 24/24 green (added `MotionTargetCodingTests` covering the `target_*` key encoding; rewrote `RobotState` decode test against a live capture).

## [2026-05-05] code | Rocky M4 — Voice pipeline base (no STT model yet)

Voice package landed with all the deterministic plumbing. STT is abstract; `EchoSTT` placeholder ships now, WhisperKit conformer follows.

- `Voice/AudioRingBuffer` — lock-protected SP/SC float32 ring; drops oldest under backpressure with a counter.
- `Voice/MicService` — AVAudioEngine input tap → 16 kHz mono float32 via `AVAudioConverter` → ring buffer. Tracks RMS for the VU meter.
- `Voice/EnergyVAD` — RMS-thresholded VAD with sliding minSpeechFrames / minSilenceFrames hysteresis. Trade-off documented vs. Silero.
- `Voice/STTEngine` protocol + `EchoSTT` test conformer.
- `Voice/WakeFilter` actor — **address-pattern** wake match (transcript must START with "rocky" after stripping leading "hey"/"ok"/punctuation/whitespace; "the rocky road" no longer matches). 60s rolling conversation window with auto-extend on each turn; stop phrases close it; `openWindow`/`closeWindow` for manual control.
- `Voice/VoiceCoordinator` actor — orchestrates frame source → VAD → STT → WakeFilter; emits `Output` events (partial, finalText with dispatched flag, windowOpened/Closed).
- `Rocky/VoiceCard` — VU meter, conversation pill (countdown when open, "waiting for wake word" when closed), last transcript, dispatched indicator, mic toggle button.
- `AppServices.toggleMic()` starts mic + voice coordinator and pumps outputs into Observable mirrors.

Tests (13 new, 37/37 total):
- `AudioRingBufferTests` (3): round-trip, overflow drops oldest, partial reads advance tail.
- `EnergyVADTests` (3): speechStart latches after enough loud frames; speechEnd after enough silent; intermittent loud frames don't latch.
- `WakeFilterTests` (6): "the rocky road" ignored; "Rocky, ..." routed; follow-up within window without wake; window expires; stop phrase closes; manual openWindow/closeWindow.
- `VoiceCoordinatorTests` (1): scripted-frame end-to-end — VAD start, segment, end → STT fires → wake match dispatches.

WhisperKit (real STT) lands next as a follow-up commit.

## [2026-05-05] code | Rocky M6 base — Cognition (LM Studio + tools)

Cognition package + dashboard wiring. Pure URLSession SSE; no SDK lock-in.

- `Cognition/JSONValue` — round-trippable JSON value type for tool args/schemas without modeling JSON-Schema in Swift.
- `Cognition/SSEParser` — minimal `data: ...\n\n` parser; tested.
- `Cognition/LMStudioClient` actor — `listModels()` + `chatStream(messages:tools:)`. OpenAI-compatible. Default `http://localhost:1234/v1`. No auth (overridable). Streams `ChatChunk(contentDelta, toolCallDeltas, finishReason)` from SSE; correlates `tool_call_deltas[i].function.arguments` across deltas.
- `Cognition/ToolRegistry` actor — schema + handler pairs; `invoke(name:argumentsJSON:llmMessageId:)` returns a `ToolResult` with full args/result/latency/ok and emits `toolInvocation` telemetry.
- `Cognition/CognitionEngine` actor — runs a turn against the LLM, dispatches tool calls (capped at `maxToolRounds = 4`), feeds results back as `tool` messages, surfaces a typed `Output` stream (`assistantDelta`, `assistantFinal`, `toolCallDispatched`, `toolCallResult`).

Initial tools wired into `AppServices.registerInitialTools()`:
- `look_at(yaw_deg, pitch_deg, duration_s?)` → `RobotLink.goto(headPose:duration:)` with RPY pose
- `set_motor_mode(mode)`
- `wake_up`, `go_to_sleep`, `stop_motion`
- `say(text)` — stub that emits `tts_request` telemetry (real TTS lands in M5)
- `get_state` — fetches `/api/state/full` and returns degree-friendly snapshot

Dashboard `BrainCard`:
- Status pill: green = model name, red = "brain offline", gray = checking
- Scrolling chat-style transcript with `you` / `rocky` / `tool` badges
- Tool calls render as expandable disclosure rows showing args/result JSON
- Latency pills on assistant messages: TTFT (first chunk) and total
- Inline text input + Send button (Return submits)
- Reset button to clear conversation

`AppServices`:
- Probes `/v1/models` on launch; flips `llmStatus` to `online(model)` or `offline(reason)` honestly.
- `sendUserText(_)` runs a turn, mirrors deltas live into `brainTurns` so SwiftUI redraws as the assistant streams.
- Voice→Brain wired: dispatched final transcripts auto-route into `sendUserText`.

10 new tests (47/47 total): SSE record boundaries + partial buffering; `JSONValue` round-trip + parsing; `ToolRegistry` happy path, unknown tool, malformed args, schemas surface.

LM Studio not running locally — confirmed graceful degradation: `BrainCard` shows "brain offline", manual sends echo a polite "(brain offline · …)" reply.

## [2026-05-05] code | Rocky M5 base — TTS via robot speaker

Voice out shipped end-to-end with a `say` placeholder backend so the wire path is provable today; F5-TTS-MLX swap is a one-file change inside the sidecar.

Sidecar `Sidecars/mlx-tts/`:

- Two pluggable backends share one `Backend` interface:
  - **`say`** (default) — macOS bundled TTS via `say -o file.aiff` + `afconvert -f WAVE -d LEI16@16000`. Always available, no Python deps.
  - **`f5-tts-mlx`** (gated behind `[mlx]` extras) — F5-TTS-MLX engine for cloned voice. Activated by `ROCKY_TTS_BACKEND=f5-tts-mlx` once the user provides a 5–10 s reference WAV.
- Methods: `synthesize(text, voice_ref_id?)` returns base64 WAV + sample rate + duration + synth_ms; `set_voice_ref(name, wav_b64)`; `health()`; `warm_up()`.
- Smoke test: `say` backend produces 1.15 s of "hi from rocky" in ~836 ms.

`RobotLink/MediaClient` actor:

- `uploadSound(filename, data)` — multipart/form-data POST to `/api/media/sounds/upload`. Returns the daemon's stored path.
- `playSound(file)` — JSON POST to `/api/media/play_sound`.
- `stopSound()` — POST `/api/media/stop_sound`.

Live wire confirmed: posted `say` output → upload (200 OK, path `/tmp/reachy_mini_sounds/rocky_test.wav`) → play_sound (200 OK) → robot's onboard speaker said "hello, I am Rocky" out loud.

`Voice/RobotTTS` actor:

- `speak(text)` — synthesize → upload → play; returns `SpeakStats(synthMs, uploadMs, totalMs, durationS)`.
- `setVoiceRef(name, wavData)` — forwards to the sidecar.
- `cancel()` — calls `stopSound`.
- `start()` / `stop()` — sidecar lifecycle.

`AppServices`:

- `mlx-tts` sidecar registered with the supervisor via a dev manifest (`/usr/bin/python3` + `say` backend). Spawned in the background on launch.
- `say` tool handler now calls `robotTTS.speak(text)` and returns real `synth_ms` / `upload_ms` / `duration_s` to the LLM.
- `stop_speaking` tool registered.

The vertical slice "voice → brain → robot" is now real end-to-end (modulo STT — WhisperKit lands as a follow-up). Once LM Studio and the user's voice reference are in place, Rocky can hear, think, and talk.

## [2026-05-05] code | M4 follow-up — Apple Speech STT + Logs view

`AppleSpeechSTT` (`SFSpeechRecognizer`-backed `STTEngine`) replaces `EchoSTT` as the runtime default. Pros: built-in, on-device when supported, no model download, no SwiftPM dep. Cons: quality lags Whisper for hard cases; we can swap in WhisperKit later via the same protocol.

- `AppleSpeechSTT.requestAuthorization()` flips the engine into `.ready` once the user grants speech-recognition permission. macOS shows the system prompt the first time when run from a packaged app; `swift run` may inherit a previous decision.
- AppServices warms it up on launch and surfaces the resolved status on the dashboard.
- `VoiceCard` shows the active STT backend.

Logs view added — closes the "is anything happening" gap when running the app:

- New sidebar: Dashboard / Logs (NavigationSplitView selection-driven).
- `LogsView` subscribes to `LogBus`, classifies events into seven categories (motor / vision / voice / brain / sidecar / link / error), tails the last 500 events.
- Filters: per-category toggles + free-text search box.
- Pause/resume button (freeze tail without dropping events) and Clear button.
- Auto-scrolls to bottom while live; pinned when paused.
- Compact monospaced rows with HH:mm:ss.SSS timestamp + colored category pill + summary line + secondary detail.

47/47 tests still green (one flake on echo-sidecar restart timing observed; passes on retry).

## [2026-05-05] code | UX polish — RockyState + animated Hero + MenuBar

Promoted Rocky's status from a static placeholder to a real state machine driving cohesive UI from one source of truth.

`AppServices.RockyState` (computed):

- `.idle` / `.listening` / `.thinking` / `.speaking` / `.error(reason)`
- Errors take priority (robot offline, voice/STT error). Speaking wins if `ttsBusyUntil > now`. Thinking wins on `brainBusy`. Listening wins when mic is on or conversation window is active. Idle otherwise.
- Synthesized from existing sub-states; no new flag plumbing beyond `ttsBusyUntil` (set after `RobotTTS.speak` returns; cleared by elapsed duration).

`HeroCard` rebuilt:

- Animated 72×72 icon: idle slow-breathe, listening concentric pulse, thinking circular spinner, speaking 4-stagger bars, error red-ring + bang.
- Color-coded "Idle/Listening/Thinking/Speaking/Error" label.
- Latency pills (LLM TTFT, STT ms, TTS first-chunk) shown when known.
- Quick action chips (Mute mic / Mute voice).
- Heartbeat ticker keeps countdowns / state-driven decisions live.

`MenuBarExtra`:

- Dynamic symbol (`circle.fill` / `ear` / `circle.dotted` / `waveform` / `exclamationmark.circle.fill`) reflects state at a glance.
- Popup mirrors the same state badge, plus quick-actions: Listen / Mute mic, Mute voice, Pause/Resume tracking, Wake robot, Sleep robot, Quit.

`AppServices` actions:

- `toggleTTSMute()` — cancels in-flight playback and gates future `say` tool calls with a structured "tts muted" error so the LLM sees the mute.
- `setFaceTrackingEnabled(_)` — forwards to the FaceTrackerService sidecar.
- `wakeRobot()` / `sleepRobot()` — trigger recorded moves via REST.
- `say` tool sets `ttsBusyUntil = now + duration_s + 0.2 s`.
- `ttsMuted` bool short-circuits `say` cleanly.

The menu bar now communicates calm-tech style — a single glanceable symbol, color-coded popup, no busy/spinning unless something's actually happening.

## [2026-05-05] code | StatusView — single-glance health panel

Added a Status sidebar destination that lists every dependency Rocky needs and what's wrong (if anything). Doubles as the "onboarding checklist" without forcing a modal flow — same checks, same actions, but always available.

Six rows, each with a status dot + detail + action button:

- **Robot daemon** — host:port + frame count when online; reason when offline. "Probe" button.
- **LM Studio** — loaded model name when online; error reason when offline. "Probe" button.
- **Microphone** — live RMS when listening; "not listening" otherwise. Toggle button.
- **Speech recognition** — Apple Speech / unauthorized / unavailable. "Authorize" button.
- **Face tracker (sidecar)** — target / detection counts when ready; failure reason; circuit-open countdown. State mirrored from `SidecarRuntime.events`.
- **TTS (sidecar)** — same lifecycle states.

Mechanical changes to make this real:

- `FaceTrackerService.sidecar` and `RobotTTS.sidecar` are now `nonisolated let` so the main actor can subscribe to their `events` streams without hopping isolation.
- `AppServices` mirrors `SidecarState` for both sidecars into Observable properties via background pumps.
- Public `probeRobotPublic()` / `probeLMStudioPublic()` so the StatusView's buttons re-run checks.

Calm-tech: when everything is green, the panel is just six green dots — no nagging.

## [2026-05-05] code | Tools + Settings + Persona editor

Added two more tool handlers and a Settings tab:

Tools:
- `play_emotion(name)` — invokes `POST /api/move/play/recorded-move-dataset/pollen-robotics/reachy-mini-emotions-library/{name}`. Schema enum constrains the LLM to 54 known emotions (amazed1, cheerful1, dance1/2/3, fear1, grateful1, laughing1, proud1, sad1, sleep1, success1, welcoming1, yes1, ...). Live-validated.
- `pause_face_tracking` / `resume_face_tracking` — forward to the FaceTrackerService sidecar's `setEnabled`. Use before a recorded emotion takes over the head.
- `RobotLink.playRecordedMove(dataset:move:)` and `listRecordedMoves(dataset:)` added.

Settings (new sidebar destination):

- Robot host + port (relaunch required to apply).
- LM Studio base URL + model + optional API key (hot-reloads via `LMStudioClient.setConfig`).
- Persona editor — full system-prompt `TextEditor` with "Reset to default" button. Default persona: short, embodied, action-oriented, latency-honest.
- Apply button (⌘S) commits to UserDefaults and re-probes LM Studio.

`SettingsStore` (`@Observable @MainActor`) is the single source of truth, persisted via UserDefaults. `AppServices.applySettings()` swaps live LM Studio + Cognition config without restarting.

## [2026-05-05] code | scripts/build-app.sh — proper .app bundle for TCC

`swift run` launches a raw executable; macOS TCC ties permission prompts and decisions to a code signature, which means mic / speech / camera prompts don't fire reliably without a real .app bundle.

`scripts/build-app.sh`:
- `swift build -c release --product Rocky`.
- Assembles `build/Rocky.app/Contents/{MacOS,Resources}/`.
- Writes `Info.plist` with `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCameraUsageDescription`, and `NSAppTransportSecurity.NSAllowsLocalNetworking=true` (so REST traffic to `reachy-mini.local` and `localhost:1234` works without exceptions).
- Ad-hoc codesigns with hardened runtime — enough for personal dev / TCC stability without a Developer ID Application certificate.

`scripts/run.sh` is a thin wrapper that builds + `open`s. Smoke-tested on this machine: arm64 Mach-O thin binary, plist parses, ad-hoc + runtime signature, all three permission descriptions present.

`build/` added to `.gitignore`. Distribution path forward (M7 follow-up): swap ad-hoc for a real Developer ID + notarization step in CI, ship via DMG.

## [2026-05-05] init | Wiki bootstrap

(Earliest entry retained for chronology — see top of file.)

## [2026-05-05] init | Wiki bootstrapped from doc pass

Documentation pass on Reachy Mini Wireless. Wiki structure created in `docs/`; project-root `CLAUDE.md` points here.

Ingested:

- HF docs (`huggingface.co/docs/reachy_mini`): index, `platforms/reachy_mini/{get_started,hardware,development_workflow}`, `SDK/{quickstart,python-sdk,core-concept,apps,integration,media-architecture,installation}`, `troubleshooting`, `sdk-tutorials`.
- `AGENTS.md` (canonical agent guide, repo root).
- Skills: `motion-philosophy.md`, `control-loops.md`.
- Examples: `look_at_image.py` (full source); examples folder listing only for the rest.

Pages created:

- Schema: `CLAUDE.md` (project root), `docs/{README,WIKI,index,log}.md`.
- Concepts: `architecture`, `motion-philosophy`, `coordinate-frames`, `safety-limits`, `media-architecture`, `app-lifecycle`.
- Reference: `hardware`, `sdk-python`, `motors`, `glossary`.
- Workflows: `dev-loop-wireless`, `create-app`, `run-and-debug`.
- Patterns: `control-loop`, `recorded-moves`, `direct-hardware`.
- Sources: `agents-md`, `hf-docs`.
- Decisions: `0001-target-platform`.

Open gaps recorded in `index.md`:

- Most `skills/` files (symbolic-motion, interaction-patterns, ai-integration, safe-torque, debugging, testing-apps, rest-api, setup-environment, deep-dive-docs, full create-app).
- Most example sources (only `look_at_image.py` ingested in full).
- JS SDK page.
- Tutorial notebooks 0 + 1.
- Live daemon OpenAPI schema.
- `media_advanced_controls`, `motors_diagnosis`.

No code written yet. Project directory still empty other than `.claude/` and the wiki.
