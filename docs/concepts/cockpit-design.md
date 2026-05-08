---
title: Rocky — cockpit design
type: concept
status: current
last_updated: 2026-05-07
tags: [rocky, ui, design, hig]
---

# Rocky — cockpit design

The design contract for Rocky's user-facing surface. Authored after multiple
rejected directions (engineer NOC, virtual-employee profile, menu-bar-first
inversion, ASCII-box pseudo-design); produced via the `swift-ui-design`
specialist with HIG grounding; refined to elevate the menu bar as the
**persistent** surface (Rocky is active when the window isn't).

If you are about to change anything visible to a user, read this document
first. The roadmap in §10 is the order in which the work is shipped.

---

## 0. Frame

The brief is uncomfortable. We don't want a NOC dashboard. We don't want a
thinly-renamed dashboard. We don't want modes. We don't want logs streaming.
We don't want the long settings scroll. We want a single window where every
pixel either tells you something you can act on or lets you act, and the
panels have to know about each other. We want the menu bar to be a
first-class surface — Rocky is active even when the window is closed.

The thesis: **Rocky is a presence, not an instrument.** When you turn to the
window, you turn because you want to talk to him, see what he just heard,
fix something, or teach him a thing. Everything else — the sidecar pills,
the motor angles, the ms-by-ms event log — is engineering substrate that
has to remain *reachable* without being *visible*.

---

## 1. Diagnosis of the pre-cockpit UI

Captured here so the rationale survives the rewrite.

### 1.1 The sidebar is the first lie

`NavigationSplitView` with five peers — Cockpit, Dashboard, Status, Logs,
Settings — frames Rocky as five apps that happen to share a sidebar. Each
panel is independent: Status doesn't link to Logs, Logs doesn't link to
Settings. The user has to hold a mental map of where things live.

**HIG (`Designing for macOS > Layout`):** a sidebar should show *peer
destinations of the same kind*. Dashboard and Cockpit aren't peers, they're
alternate views of the same thing. Status, Logs, Settings are *secondary*
— diagnostic and configuration surfaces, not primary destinations.

### 1.2 Typography has no system

Hand-rolled font calls everywhere — `.system(size: 28, weight: .bold,
design: .rounded)` (Dashboard / Status / Logs / Settings headers, repeated
rather than expressed once), `.system(size: 30, weight: .semibold,
design: .rounded)` (Hero), `.system(size: 24, ..., .rounded)` (Cockpit
prototype), `.system(size: 13/14/16, weight: .semibold)` scattered
throughout. There's no scale. Every screen looks like it was designed
standalone.

**HIG (`Typography`):** macOS apps use `.largeTitle` / `.title` / `.title2`
/ `.title3` / `.headline` / `.body` / `.callout` / `.footnote` /
`.caption`. Custom sizes need a reason; "I want it rounded" is not a
reason that survives across 30 views.

### 1.3 The card chrome fights the window

`Card.swift` paints `.background.opacity(0.4)` with `.white.opacity(0.06)`
strokes and `.black.opacity(0.20)` shadows over a hand-rolled
`LinearGradient` background. This is a *dark theme baked into the geometry*.
In light mode the strokes vanish and the shadows go grey-on-grey. The
window is also locked to a dark gradient regardless of system appearance.

**HIG (`Materials`):** macOS gives `.regularMaterial`, `.thickMaterial`,
`.thinMaterial`, `.windowBackgroundColor`. They adapt to light/dark,
vibrancy, and Reduce Transparency. Hand-rolled gradients are forbidden
unless we're imitating the system explicitly. Stacking heavy shadows on
every card flattens hierarchy — when everything pops, nothing pops.

### 1.4 Status pills are over-budget

`StatusPill` is everywhere: connection badge, model badge, listening
countdown, mic state, motor mode, frame counter, conversation pill, Logs
filter chips. The Hero card has 4–6 pills competing with the avatar.
Status contains seven pills that all turn green on a happy day — once a
user learns "they should all be green," the pills stop being read.

**HIG (`Information Hierarchy`):** indicators that always show "ok" become
invisible. Reserve high-attention chrome for *exceptions*. Healthy states
should be quiet, even absent.

### 1.5 The Hero card is doing too much

It carries: 3D head (280×280), name + state label, BotMode badge, two
latency pills, error string, big Wake/Sleep button, mic toggle, TTS mute
toggle. A portrait, a status panel, a control row, and a mode banner
stacked on top of each other.

### 1.6 The Brain card duplicates the Cockpit centre

Both render `services.brainTurns`. Both have a text input. Both autoscroll.
Both render TTFT/total ms badges. The Cockpit also adds a "remember:"
inline write and a "why no reply?" diagnose card. Two surfaces, one job.

### 1.7 Logs are useless because they're firehose

Already known. The right rhythm for human-facing activity is **one entry
per moment**, not one entry per event. A user turn → a Rocky turn → a
tool call → an error counts as four moments. State frames, mic RMS
samples, llm chunks count as zero.

### 1.8 Settings is a wall of fields

Eight cards, ~25 controls, all stacked, all visible, no progressive
disclosure. Persona is a 200-pt-tall TextEditor sitting next to a
face-match-threshold slider next to a TTS engine picker — same visual
weight.

**HIG (`Settings`):** on macOS, Settings is a separate window with tabs.
`Settings { TabView { ... } }`. Settings inside the main window is an
iPadism. `.keyboardShortcut("s", modifiers: .command)` for "Apply" is
wrong on macOS — ⌘S is "save document"; settings should apply on edit
or via a clearly-labelled per-section button.

### 1.9 Status is a triage room with no triage

Seven rows, identical visual priority. If the robot is offline, *that's
the thing that matters* — every other row is downstream. The view should
collapse to the worst problem first, with the rest deferred.

### 1.10 The first cockpit prototype borrowed the dashboard's vocabulary

It put a header pill, a hearing strip, a transcript, a text field, a
memory inline write, a "replay 30s" stub, and a "diagnose" card in vertical
order — and called it Cockpit. Every section is a small card, the
typography is the same as the Dashboard, the visual centre is still text.
**The cockpit must look different at first glance, not just be labelled
differently.**

### 1.11 macOS-native conventions broken in small ways

- The window has no toolbar. macOS apps put primary actions in `.toolbar`.
- The `MenuBarExtra` is an afterthought, not a real surface.
- There's no `Settings` scene.
- No use of `.inspector(isPresented:)` — exactly the macOS pattern for
  "an opt-in side panel of details".
- The Hero card has fixed sizes; the window is a stack of fixed-size
  things, not a layout that breathes.

### 1.12 Accessibility is an afterthought

- Many pills have no `.accessibilityLabel`; VoiceOver reads "ok ok ok ok".
- Custom font sizes don't scale with Dynamic Type.
- The dark gradient ignores Reduce Transparency.
- The 3D head has no `.accessibilityElement` description.
- Animations ignore Reduce Motion.

---

## 2. The thesis: a single window with a stage and a margin, plus a persistent menu bar

### 2.1 Attention hierarchy (five layers, ordered by frequency of contact)

1. **System notifications** — exceptional moments only.
2. **Menu bar icon** — always visible, animated by state. The only Rocky
   surface there all day.
3. **Menu bar popover** — click the icon → ~80% of interactions. Glance,
   ask one thing, mute, pause, see the last exchange.
4. **Cockpit window** — opened when you sit down to *work with* Rocky.
   Stage + conversation + margin + inspector.
5. **Settings window** — opened when configuring.

The window is no longer "the app." The menu bar is the app. The window is
what you open when you have time. Rocky is **active when the window is
closed** — for short interactions (mute, ask one thing, glance, pause)
opening a 1100pt window is friction.

### 2.2 The window's anatomy

- **A stage** — Rocky himself, presented as a calm, alive presence, with
  the conversation flowing alongside him.
- **A margin** — peripheral information that's there if you look for it,
  otherwise quiet (the moment feed).
- **A drawer** — the inspector you summon when you want the engineering
  substrate.
- **A toolbar** — the macOS-native top strip with the few global actions.

Three layers. The stage is daily. The margin is glanceable. The drawer is
on-demand.

This is not "modes." There is one window in one configuration. The drawer
slides in when you want it; the toolbar is always there.

---

## 3. Information architecture of the window

### 3.1 The stage (~60% of window)

Two panels share the stage, side-by-side, with a draggable divider, default
**40 portrait / 60 conversation**. The divider can collapse the portrait
to a strip when more transcript real estate is wanted, but it cannot
disappear — the avatar is the soul of the app.

**Left: the Portrait.** The 3D head from `ReachyHead3D`, generous square
frame filling its column. No card chrome, no header, no latency pill. The
head is the only thing in the column. Underneath:

- **Line 1** — Rocky's name, `.title2.weight(.semibold)`.
- **Line 2** — *one* sentence of presence in `.callout`, secondary colour.
  Function of `botMode × rockyState`:
  - "Rocky is asleep. Tap his head to wake him."
  - "Rocky is awake, watching you."
  - "Rocky is listening to Ade."
  - "Rocky is thinking."
  - "Rocky is speaking. Volume 70%."
  - "Rocky needs help — robot offline."

Below that, **one** primary action that follows state (Wake / Sleep / Mute
/ Stop talking). Not three buttons.

The Portrait *is* the status display. When the head's eyes blink, the
antennas tip, the head slumps in sleep, the eyes track a face — those
animations carry state. We delete the BotMode badge and the latency pills
entirely from the stage.

**Right: the Conversation.** A single, generous transcript:

- One bubble per turn. User bubbles right-aligned, accent-tinted, 70% width.
  Rocky's left-aligned, primary-tinted, 70% width. Tool calls render as a
  thin "Rocky used `current_time`" pill, indented, dimmed, collapsible.
- TTFT/total ms render *only on hover* on Rocky's bubbles.
- Long tool-detail JSON behind a "show detail" disclosure, default closed.
- Above the transcript: a slim hearing strip — VU meter (40pt × 4pt, tiny
  on purpose) + `.callout`:
  - listening: live STT partial in italic primary
  - idle: "say Rocky to start" in secondary
  - muted: "mic off — toolbar to enable" in tertiary
- Below the transcript: input row. `TextField` in `.roundedBorder` with
  placeholder "Ask Rocky, or say his name." Trailing send button. Leading
  mic-toggle that mirrors the toolbar's; clicking it shows a popover
  ("the mic toggle is also in the toolbar; both work"); suppressed after
  two uses. Intentional redundancy — the conversation deserves a
  self-contained input strip.

The conversation is the only place the user types or reads content.
`BrainCard`, `VoiceCard`, and the rejected cockpit prototype's transcript
all unify here.

### 3.2 The margin — the moment feed (~32pt strip)

A thin, *quiet* strip at the bottom of the conversation column. Replaces
both `LogsView` and the rejected prototype's "diagnose" card.

A "moment" is one of:

- A user turn (collapsed if rendered above in transcript)
- A Rocky turn (collapsed if rendered above)
- A tool invocation result
- A face enrolled / recognised / lost
- An error or recovery
- A wake or sleep transition
- A sidecar lifecycle change (started, stopped, failing, recovered)

Each row: a 14pt SF Symbol + one sentence in `.callout` + relative
timestamp (`2m`, `35s`, `now`). Click to expand inline (3-row detail).
New moments crossfade in over 250ms; the strip never autoscrolls fast
enough to feel like a stream.

"See all" affordance → opens the inspector to its Activity tab. The
firehose `LogsView` becomes a *developer-only* tab inside the inspector.

The margin is honest about silence. *"All quiet. Last moment: Rocky
greeted Ade, 4m ago."*

### 3.3 The toolbar

A native macOS `.toolbar`, left to right:

- **Wake/Sleep** — primary action button, `sun.max.fill` / `moon.fill`.
- **Mic toggle** — `mic.fill` / `mic.slash`, `.symbolEffect(.pulse)` while
  listening.
- **Voice toggle** — `speaker.wave.2.fill` / `speaker.slash.fill`.
  Right-click reveals a volume slider in a popover.
- **Spacer**.
- **Robot health glance** — single SF Symbol (gray / green-pulse-once /
  orange / red). Click → inspector / Health tab. Hover → tooltip names
  the worst issue.
- **Inspector toggle** — `sidebar.right`.
- **Settings** — `gear`, opens the Settings scene.

Seven items. No status pills. The toolbar is the boundary between
*Rocky as character* (the stage) and *Rocky as system* (everything to
the toolbar's right).

### 3.4 The inspector — the engineering drawer

`.inspector(isPresented:)`, ~360pt wide, trailing edge. Tabs:

1. **Health** — current `StatusView` reorganised by severity. Robot daemon
   row at top. Worst issue next. Healthy items collapse into a single
   "All other systems healthy" disclosure, default closed. Each row keeps
   its inline action.
2. **Activity** — moment feed at full height, with filter pills (turn /
   vision / voice / brain / sidecar / error) and a search field.
3. **Memory** — drawer count, recall toggle, top-K slider, recent drawers
   list with previews, "forget everything" destructive action,
   "remember:" inline-write field with pin toggle.
4. **Motion** — current `MotionCard` content. Compact.
5. **Vision** — current `VisionCard` content.
6. **Raw** — the firehose `LogsView` preserved verbatim. Off by default;
   toggle "show raw events" reveals.

Every existing piece ends up here, just reorganised. This is the strongest
"everything that exists must remain" honour-clause.

`minWidth` 1100 with inspector visible, 760 without.

### 3.5 The menu bar — the persistent surface

The menu bar is **always available**, all day. The window is *occasional*.
Most short interactions live here.

**Icon (always visible)** — single SF Symbol whose animation conveys state.
No badges, no counts:

| State | Icon | Animation |
|---|---|---|
| Asleep | `moon.zzz` dimmed | none |
| Idle awake | `circle.dotted` | gentle breathing pulse |
| Watching (face in view) | `eye` | once-on-detection bounce |
| Listening | `ear` | `.symbolEffect(.pulse, options: .repeating)` |
| Thinking | `brain` | `.symbolEffect(.variableColor)` |
| Speaking | `waveform` | `.symbolEffect(.bounce, options: .repeating)` |
| Error | `exclamationmark.triangle.fill` amber | `.symbolEffect(.bounce)` once |
| Robot offline | `wifi.exclamationmark` red | none |

Reduce Motion respected: animations become a static colour change.

**Click reveals popover (~360 × ~520pt)** — top to bottom:

- **Presence row** — small portrait icon (32pt thumbnail / stylised
  glyph) + Rocky's name in `.headline` + the same one-sentence presence
  line that lives under the cockpit's portrait.
- **Recent moments** (last 3) — moment-feed rows, capped to three.
- **Last exchange** — most recent user-Rocky pair, two bubbles. Catch
  up at a glance.
- **Ask Rocky** — `TextField` + send. Goes through `sendUserText`. Reply
  lands as a new "last exchange." This is the single-question shortcut
  — most of the time you'll use it instead of opening the window.
- **Quick controls** — Wake/Sleep · Mic mute · Voice mute · "Pause Rocky
  for 30 min" with a countdown when active. Right-click on Voice opens a
  volume slider.
- **Health affordance** — one line: "All clear." or "1 issue — Memory
  sidecar offline." Click → main window with inspector / Health.
- **Open Rocky** button — `⌥⌘R`.

The popover stays open until you click outside or press Escape. So you
can: open → ask one thing → read reply → escape, all without
context-switching apps.

**Global hotkey `⌥⌘R`** — pops the popover with focus on the input from
anywhere. Also dismisses. Configurable.

### 3.6 Notifications — the loudest surface

System notifications must be **rare**.

**Notify (default):**
- Face recognised that hasn't been seen in 24h
- Robot offline (after 30s of unreachability)
- Sidecar circuit-breaker tripped (after retries exhausted)
- Pinned memory matched the current turn

**Don't notify:**
- Every successful turn
- Every face detection
- Every wake / sleep transition
- State frame errors, transient sidecar restarts

The bar for a notification: "the user would want to know even if their
hands are full."

### 3.7 Settings (separate scene)

`Settings { TabView { ... } }` with six tabs: **Robot, Brain, Voice,
Memory, Faces, Persona**. Each tab is a `Form` with grouped sections.
Apply-on-commit by default; the relaunch-required notice for the robot
endpoint becomes a labelled badge on the field. ⌘, opens it.

The persona TextEditor gets its own tab so it has the room it needs.

The first-run flow walks through tabs 1, 2, 3, 5 — making the Settings
window legible on its own as a place to revisit afterwards.

---

## 4. Visual & typographic system

Adopt these explicitly; remove all hand-rolled font calls.

### 4.1 Typography ladder

| Role | Style | Usage |
|---|---|---|
| Window title (Rocky's name on stage) | `.title.weight(.semibold)` | Once, on stage |
| Section headline | `.title3.weight(.semibold)` | Inspector tabs, Settings tabs |
| Body | `.body` | Settings field labels, moment feed, transcript |
| Conversation prose | `.callout` | The bubbles |
| Caption | `.caption.foregroundStyle(.secondary)` | Timestamps, latency |
| Footnote | `.footnote.foregroundStyle(.secondary)` | Microcopy under controls |

`SF Pro` default — no `.rounded` design except possibly for Rocky's name
itself (try without first).

**Delete every `.font(.system(size: ...))` call** unless deliberate (e.g.
`.body.monospacedDigit().weight(.medium)` on dial readouts).

Every text style scales automatically with Dynamic Type. Test at the
largest accessibility size.

### 4.2 Spacing scale

Four steps:

- **4pt** — tight (icon-to-text inside a button or pill)
- **8pt** — close (label + control)
- **16pt** — section (between unrelated items in the same group)
- **24pt** — region (between major regions)

The codebase currently uses 6, 8, 10, 12, 14, 16, 18, 20, 22, 24 — pick
four; reject the rest.

### 4.3 Materials and surface

The window background uses `.background` (system-driven) with no overlay
gradient. Light mode looks light, dark mode looks dark. Portrait column:
plain `.background`. Conversation column: `.regularMaterial`. Inspector:
`.thickMaterial` (macOS standard for trailing inspectors). Toolbar: the
toolbar — system handles it (Liquid Glass on macOS 26 automatic).

Replace every `.fill(.gray.opacity(0.08))` with `.background(.quaternary)`
or `.fill(.tertiary)` — semantic, dark-/light-aware, accessible.

**Cards become rare.** The transcript area is not a card. The portrait
area is not a card. The moment feed is not a card. Cards return only
inside the inspector where the grouping itself is meaningful. Replace
`Card` chrome with: `.padding()`, `.background(.regularMaterial, in:
RoundedRectangle(cornerRadius: 12))`, no shadow, no manual stroke.
Shadows fight materials.

### 4.4 Colour intent

- **Accent** (system) — primary actions, user identity in transcript,
  focus rings. *Not* "this is the active state" badges everywhere.
- **Semantic** (system green / orange / red) — only for *exceptional*
  state. Green is for **transition** moments, not steady states.
- **System gray scale** (`.primary`, `.secondary`, `.tertiary`) —
  everything else. The vast majority of UI.

The "everything is a tinted pill" approach gets reduced ~80%. Pills exist
for: the toolbar's robot-health glance icon and inspector / Health rows.
Nowhere else.

### 4.5 Motion language

A small, named set:

- **Presence** — head idle motion (breathing, antenna twitch). Already in
  `ReachyHead3D`. Keep.
- **Pulse** — mic icon during active listening. `.symbolEffect(.pulse,
  options: .repeating)`.
- **Bloom** — when Rocky speaks, the head outline glows briefly.
- **Crossfade** — moment feed entries cross-fade. 250ms ease-in-out.
- **Slide-from-edge** — inspector summon, settings sheet. Native.

Every motion respects `@Environment(\.accessibilityReduceMotion)`. When
reduced, animations switch to instant state changes — except the head's
pose (which is *information*, not decoration).

---

## 5. The moment feed in detail

### 5.1 Moment kinds

Mapped to existing `TelemetryEvent` cases:

| Moment | Generated from |
|---|---|
| `userSaid(text)` | `sttFinal` that is also `wakeMatched`, OR typed `sendUserText` |
| `rockySaid(text, tools)` | end of an assistant turn |
| `rockyHeard(text, dispatched: false)` | `sttFinal` without wake match |
| `recognised(person)` | `faceDetection` whose identity hasn't been seen in 30s |
| `lost(person)` | tracked identity hasn't been seen for 30s |
| `enrolled(person)` | result of `enrollFace` |
| `wokeUp` / `wentToSleep` | wake/sleep transition |
| `errorOccurred(scope, message)` | `error` event |
| `recovered(scope)` | next non-error event in same scope after one |
| `sidecarChanged(name, state)` | `sidecarState` transitions only |
| `toolUsed(name, summary)` | `toolInvocation` (collapsed under the user turn) |

Notably absent: motor commands, motor state frames, mic RMS samples, llm
chunks, daemon heartbeats, face targets per frame.

### 5.2 Coalescing

Three faceDetections of "Ade" in 5 seconds = one "Recognised Ade" moment.
Four llm chunks of one sentence = one `rockySaid`. A sidecar fails three
times in 30 seconds = one `errorOccurred(scope: .sidecar)` followed by
`recovered` only when it stays up for 60s.

A new `MomentFeed` actor downstream of `LogBus` listens to
`TelemetryEvent` and emits coalesced `Moment`s on its own `AsyncStream`.
Ring buffer (last 200), debounce timers per moment-kind.

### 5.3 Layout

**The strip** — 32pt bottom of conversation column. Last *one* moment by
default; hover expands to 4 rows (~128pt). Hovering away collapses.

**The Activity tab** — scrollable list, newest-first, filter pills
(turn / vision / voice / brain / sidecar / error), search field. Click
expands inline.

### 5.4 Density

A row is one line of `.callout` with icon + sentence + relative timestamp.
No millisecond timestamps. No hex IDs. No raw category labels. Templated
sentences:

- ▸ "Ade said: 'remind me to call Mum at five.'" — 12s
- ◆ "Rocky used `set_reminder` and replied: 'Got it.'" — 12s
- ✦ "Rocky recognised Ade." — 4m
- ⚠ "Mic permission denied — fix in System Settings." — 4m

---

## 6. Cross-panel interactions

The brief: "panels know about each other." Concrete cross-references:

- **Click a face label in Vision tab** → filter Activity to "moments
  involving Ade" → scroll transcript to most recent Ade exchange →
  portrait tooltip "watching Ade."
- **Click a Rocky bubble's tool-pill** → expand to args/result inline →
  pulse the corresponding row in Activity if open.
- **Hover the moment-feed strip's "Mic permission denied" row** →
  toolbar mic icon highlights amber → click opens System Settings.
- **Click a face in the conversation transcript** → scroll Activity to
  the recognition moment → pulse the Vision tab's bbox label.
- **Hover toolbar Robot Health glance** → tooltip names the worst issue
  → click opens inspector / Health scrolled to the offline row.
- **Drag the portrait** → divider moves; collapsing all the way left
  reduces it to a 60pt strip. Click strip to restore.
- **`⌘K`** → command palette: "Wake / Sleep / Mute mic / Mute voice /
  Open inspector / Search transcript / Search memory / Forget last 5
  minutes / Re-enrol face." Long-term spine for new actions.
- **Sidecar starts failing** → moment feed: "Memory sidecar failing —
  auto-restarting." → toolbar health icon amber, `.symbolEffect(.bounce)`
  once. No popup. No notification. Presence stays calm: "Rocky is awake.
  Something needs your attention." If still down after 30s, a small
  banner slides into the strip: "Memory recall paused — Rocky is talking
  from short-term memory only." Escalation has stages.

These aren't gimmicks. Each is a place where two panels share information
the user would otherwise have to hold in their head.

---

## 7. Settings reorganisation

Six tabs in this order:

1. **Robot** — host, port, "applies on relaunch" badge. Adds: probe-now
   button + result line. Adds: a disclosure showing
   `~/Library/Application Support/Rocky` paths.
2. **Brain** — LM Studio URL, model picker, API key, persona moves into a
   collapsible "edit persona" disclosure. "Reset to default persona"
   button. Hot-reload on edit; autosave indicator replaces "Apply".
3. **Voice** — mic source picker, TTS engine picker, robot speaker volume.
   Adds: voice cloning prompt button (later).
4. **Memory** — recall toggle, top-K slider, drawer count, "forget
   everything." Live drawer count, updates over time.
5. **Faces** — enrolment form, threshold slider, enrolled list. Cleaner
   layout because it's not crammed against five other cards.
6. **Persona** — full-width, full-height TextEditor, character count, save
   indicator, "test on next turn" quick action. Splitting persona out
   from Brain prevents it from squashing the small numeric fields.

Apply-on-edit replaces the global "Apply." Robot endpoint is the sole
exception — pressing Return commits and the badge says "applies at next
launch."

---

## 8. Status / Diagnostics

Three placements:

- **At-a-glance, always visible**: toolbar Robot Health glance icon. One
  symbol, three states.
- **On request, in-window**: inspector / Health tab. Reorganised by
  severity. Worst issue first; healthy items folded into a single "5
  systems healthy" disclosure. Heading: "1 issue. 6 healthy."
- **Background, in moment feed**: sidecar lifecycle transitions, daemon
  outages, permission denials surface as moments at the time they happen.

The seven pills don't disappear — they live in inspector / Health. They
don't appear in the cockpit's stage.

---

## 9. Onboarding — a 6-step first-run

Triggered when `AppServices.start()` runs without a `firstRunCompleted`
flag. Translucent overlay over the cockpit window; portrait centred; no
transcript; no toolbar.

1. **Meet** — Rocky asleep. "This is Rocky. He's a desktop robot, and
   this window is where you'll work with him. He's currently asleep."
   Single button: "Wake him up." Click → he animates awake.
2. **Connect** — detects daemon. If green: "Rocky is connected to the
   robot at reachy-mini.local." If red: a single host field, probe button,
   inline result. Just *the one thing that has to be true* to continue.
3. **Brain** — probe LM Studio, show the model. If multiple, one-tap pick.
   If LM Studio isn't running, "open LM Studio" + "I'll set this up
   later." Rocky still wakes.
4. **Say hello** — "Try saying 'Rocky, what's your name?' or type below."
   A TextField appears. Portrait moves alongside. After one successful
   turn, the step completes.
5. **Teach him your face** — "Rocky says hi when he recognises you. Want
   to teach him your face now?" Two buttons: "Use my camera" or "Maybe
   later." Photo enrolment via `.fileImporter` alternative.
6. **The cockpit** — overlay dissolves. Toolbar fades in. Inspector
   handle becomes visible. Coachmarks: mic toggle, inspector handle,
   moment feed strip. After three acks the flag commits.

Total controls touched: maybe 4. Total fields filled: 1 (host, only if
needed). The first-run is a story, not a form. Technical setup happens
*as a side effect of the story*: probing the daemon, picking a model,
enrolling a face. The user never reads the word "sidecar."

`Help > Show first run` re-opens the flow afterwards.

---

## 10. Implementation roadmap

Six waves, each independently shippable. Work in order.

### Wave 1 — Reframe + the persistent menu bar (~2–3 sessions)

- Adopt `.toolbar` on the cockpit detail. Wake/Sleep, Mic, Voice, Health
  glance, Inspector toggle, Settings.
- Move Status, Logs, Memory, Motion, Vision into `.inspector(...)` tabs.
  Re-export existing views verbatim.
- Move SettingsView into a real `Settings { TabView { ... } }` scene.
- Sidebar collapses to the single Cockpit detail (or removed entirely).
- **Promote MenuBarStatusView to a full popover**: animated icon driven by
  `services.rockyState`, presence row, last 3 moments (placeholder until
  Wave 4), last exchange, "ask Rocky" input, quick controls (wake/sleep,
  mic, voice, pause-for-X), open-Rocky button.
- New `services.dndUntil: Date?` for the pause control; gates wake filter
  and TTS dispatch.
- `⌥⌘R` global hotkey via `NSEvent.addGlobalMonitorForEvents`.

Visible win: macOS-shaped app. One window detail. One toolbar. One
inspector for diagnostics. One Settings window. The menu bar becomes a
real always-on surface — most short interactions never open the window.

### Wave 2 — Typography and chrome (~1 session)

- Define type scale (six roles in §4.1).
- Replace every hand-rolled `.font(.system(size:))` call.
- Remove the hand-rolled `BackgroundGradient`. Use system window
  background.
- Kill `Card.shadow`. `Card.background` → `.regularMaterial`. Drop manual
  stroke borders.
- Reduce StatusPill calls by ~80%.

Visible win: stops looking like a custom shell, starts looking macOS.
Light mode works. Dynamic Type works. Reduce Transparency works.

### Wave 3 — The stage (~2–3 sessions)

- New portrait + conversation split for the cockpit detail.
- Reuse `ReachyHead3D` unchanged. Reuse `services.brainTurns`.
- New single `ConversationView` subsumes `BrainCard`, `VoiceCard`, and the
  rejected cockpit prototype's transcript.
- Hero card stripped to head + name + presence sentence + one primary
  action; the chips moved to the toolbar in Wave 1.
- Hearing strip simplified, above the conversation.
- Input row with the integrated mic-toggle.

Visible win: the cockpit looks fundamentally different from the dashboard.

### Wave 4 — The moment feed (~2 sessions)

- Build `MomentFeed` actor downstream of `LogBus`.
- Build the strip view (32pt, hover-to-expand) bottom of conversation.
- Build the Activity tab with filters and search.
- Mark `LogsView` as the "Raw" tab. Default off.
- Menu bar popover's "recent moments" section flips to subscribing from
  MomentFeed.

Visible win: human-cadence "what just happened" instead of firehose.
Engineering log is one click away.

### Wave 5 — Settings re-tab + first-run (~2 sessions)

- Split `SettingsView` content into the six tabs in §7.
- Apply-on-commit per field.
- Build the 6-step first-run as an overlay on the cockpit window.
- Wire `firstRunCompleted` and `Help > Show first run`.

Visible win: a brand new owner gets a coherent introduction. The 25-field
wall is gone.

### Wave 6 — Cross-panel polish + accessibility (ongoing)

- Implement §6 cross-references one at a time.
- `.accessibilityLabel` everywhere. VoiceOver paths. Dynamic Type at
  largest size. Reduce Motion.
- Profile motion performance.
- Menu bar icon accessibility pass (VoiceOver labels for animated states,
  keyboard nav within popover).

Visible win: composed, not assembled.

---

## 11. Notes on specific decisions

**Why no menu-bar-only design.** The menu bar is the *persistent* surface,
not the only one. Long conversations, deep memory inspection, debugging,
configuration — those want real estate. The window is where you go for
those.

**Why no modes.** A mode says "you are using the app in a particular way
right now." Rocky has no modes — he has *states*. The window is one shape;
the inspector slides in or out.

**Why portrait-as-centre.** The transcript is what you read; the portrait
is what you feel. The product positioning ("a virtual coworker with a
body") fails the moment the visual centre is text. The avatar is the only
thing that gives the engineering substrate (mic on, listening, thinking,
speaking) a non-instrumental form. Without the portrait at centre, this
is just an LLM chat client with extra hardware bills.

**Why the moment feed at the bottom of the conversation, not the top.**
Reading happens from the input upwards. The most recent moment is closest
to the most recent action. Top would force the eye to leave the
conversation.

**Why Vision and Motion leave the front door.** They're *output ports for
engineers*, not affordances for the user. The user doesn't change motor
mode by reading a body-yaw dial. Both views remain perfect tools — they're
in the inspector, one tab click away.

**Why apply-on-edit settings.** Each field knows its own apply path. Most
apply instantly. Robot endpoint stages. The user thinks "I changed it, it
changed."

**Why the menu bar is in Wave 1, not Wave 6.** Rocky is *active when the
window is closed*. The menu bar isn't a polish item; it's the surface most
short interactions go through. Treating it as polish would mean shipping
the wrong primary surface.

---

## 12. What this design is explicitly *not* saying

- The avatar doesn't need to be redesigned. `ReachyHead3D` is good. Don't
  touch it in Wave 3 except to reframe it.
- We don't need a new colour palette. System accent + semantic + gray is
  enough. Pick that, *use it consistently*.
- The architecture (wake filter, cognition engine, sidecar host, memory
  service) is sound. Only the UI surface changes.
- Liquid Glass doesn't need to be everywhere. It arrives automatically on
  macOS 26 wherever we use system materials and toolbars. Resist
  `.glassEffect()` on content.

---

## 13. Files of note

- `Sources/Rocky/RootView.swift` — sidebar lives here; Wave 1 reshapes
- `Sources/Rocky/RockyApp.swift` — Wave 1 adds the Settings scene; Wave 1
  promotes MenuBarExtra
- `Sources/Rocky/Cockpit/CockpitView.swift` — replace with the stage in
  Wave 3
- `Sources/Rocky/HeroCard.swift` — Wave 3 strips this down
- `Sources/Rocky/BrainCard.swift` — Wave 3 absorbs into ConversationView
- `Sources/Rocky/VoiceCard.swift` — Wave 3 absorbs the input bar
- `Sources/Rocky/MotionCard.swift` — Wave 1 moves into Inspector / Motion
- `Sources/Rocky/VisionCard.swift` — Wave 1 moves into Inspector / Vision
- `Sources/Rocky/StatusView.swift` — Wave 1 moves into Inspector / Health
- `Sources/Rocky/LogsView.swift` — Wave 1 moves into Inspector / Raw
- `Sources/Rocky/SettingsView.swift` — Wave 1 wraps in Settings scene;
  Wave 5 splits into six tabs
- `Sources/Rocky/UI/Card.swift` — Wave 2 strips chrome
- `Sources/Rocky/UI/ReachyHead3D.swift` — the stage portrait. Untouched
- `Sources/Rocky/MenuBarStatusView.swift` — Wave 1 promotes to full popover

New files this design implies:

- `Sources/Rocky/Cockpit/PortraitView.swift`
- `Sources/Rocky/Cockpit/ConversationView.swift`
- `Sources/Rocky/Cockpit/MomentStrip.swift`
- `Sources/Rocky/Inspector/InspectorView.swift`
- `Sources/Rocky/Inspector/HealthTab.swift`
- `Sources/Rocky/Inspector/ActivityTab.swift`
- `Sources/Rocky/Inspector/MemoryTab.swift`
- `Sources/Rocky/Inspector/MotionTab.swift`
- `Sources/Rocky/Inspector/VisionTab.swift`
- `Sources/Rocky/Inspector/RawTab.swift`
- `Sources/Rocky/MenuBar/MenuBarPopover.swift`
- `Sources/Rocky/Onboarding/FirstRunOverlay.swift`
- A new `MomentFeed` actor under `Sources/Telemetry/` (the coalescing
  logic).

---

## 14. The shortest version

The window has a stage and a margin. The toolbar has the controls. The
inspector has the engineering. Settings is a separate window. The moment
feed replaces the firehose. Onboarding is a story not a form. The portrait
is the centre.

**The menu bar is the persistent surface** — Rocky is active when the
window is closed; most short interactions never open the window.
