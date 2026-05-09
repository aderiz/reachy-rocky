---
title: Permissions authority
type: concept
status: current
last_updated: 2026-05-08
sources:
  - Sources/Rocky/Permissions/PermissionsAuthority.swift
  - scripts/build-app.sh
tags: [permissions, tcc, signing, macos]
---

# Permissions authority

Rocky needs four user-grantable macOS permissions:

| Permission         | What for |
|--------------------|----------|
| Microphone         | Listening (only when `micSource == "mac"`; the robot mic doesn't go through TCC). |
| Speech Recognition | Local STT via `SFSpeechRecognizer`. |
| Calendar           | The `read_calendar` tool ("what's on tomorrow?"). |
| Location           | The `get_weather` tool (so the LLM doesn't have to ask which city). |

`Sources/Rocky/Permissions/PermissionsAuthority.swift` is the **single
source of truth**. Every UI surface (FirstRunOverlay, Settings →
Permissions, the StatusView Health rows) and every tool guard
(`LocationProvider`, `CalendarTool`) reads from this class instead of
calling the OS APIs directly. Reason: scattered readers diverge.
Without this, the onboarding overlay would say "granted" while the
tool said "denied," or two surfaces would map `.writeOnly` differently.

## Five-state model

`Status` has five cases, not three:

```swift
enum Status: Sendable, Equatable {
    case granted
    case limited(reason: String)
    case denied
    case notDetermined
    case restricted
}
```

`limited` is the case that earns its keep. Calendar's `.writeOnly`
("Add Events Only" in System Settings) is half-grants Rocky enough to
write events but not enough to read them. Collapsing it to `.denied`
told the user "Denied" when the OS UI said "Add Events Only" — they
went round in circles. The `reason: String` carries the explanation
the UI shows.

`restricted` is parental controls / MDM — the user can't change it
without admin help. The UI surfaces this differently (no "Open System
Settings" button, since that wouldn't help).

## Always-fresh reads

`PermissionsAuthority` does **not** cache state internally. Each call
to `refresh()` re-reads all four OS APIs. The class is `@Observable`,
so the read updates the published properties and SwiftUI re-renders
automatically.

`refresh()` fires:

- On init.
- On `NSApplication.didBecomeActiveNotification` — picks up changes
  the user made in System Settings without having to restart Rocky.
- After every `request(_:)` completes.
- Explicitly from `applicationDidUpdate` and a few other surfaces.

## The `requestAuthorization` pitfall (Speech)

`SFSpeechRecognizer.authorizationStatus()` is a **per-process cache**
that does not invalidate when the user toggles the permission in
System Settings. So:

1. User declines on first launch → cache holds `.denied`.
2. User goes to System Settings → Privacy → Speech Recognition →
   toggles Rocky on.
3. Rocky's `authorizationStatus()` still returns `.denied` because
   nobody invalidated the cache.

The fix is to route through `SFSpeechRecognizer.requestAuthorization`,
which reads from out-of-process state. `request(.speechRecognition)`
in `PermissionsAuthority` does exactly this — it does not re-prompt
once a decision exists, but it returns the *current* OS state.

The synchronous `readSpeechRecognition()` is still called for fast
reads on `didBecomeActive`; the request path is the canonical
fresh-read.

## The "permissions against the debug binary" pitfall

This is the source of the most-frequent permissions report
("permissions are granted but Rocky says denied"). It comes from
how macOS ties TCC to the binary that *requested* the permission.

When you run `swift run Rocky`, the OS sees the executable at
`.build/debug/Rocky` with the SwiftPM-toolchain code signature. Any
permissions you grant are tied to *that* CDHash. When you then run
`./scripts/build-app.sh` and launch `build/Rocky.app`, the binary at
`build/Rocky.app/Contents/MacOS/Rocky` has a *different* CDHash, so
TCC treats it as a different app. Result: the Settings UI shows
Rocky toggled on (against the .app), but the .app itself sees
`.notDetermined` and prompts again — or worse, sees `.denied` because
of an old grant against the debug binary.

**Practical rules:**

- Always launch via `build/Rocky.app` for testing TCC flows.
  `swift run` does not exercise the prompt path reliably.
- If permission state is confused, run:
  ```
  tccutil reset Microphone           ai.amplified.Rocky
  tccutil reset SpeechRecognition    ai.amplified.Rocky
  tccutil reset Calendar             ai.amplified.Rocky
  ```
  then re-launch the .app.
- The `⌘R` Run action in Xcode also exercises the SwiftPM debug
  binary path — same problem.

## Signing flow

`scripts/build-app.sh` enforces the signing strategy that makes TCC
grants persist across rebuilds:

1. **Apple Development / Developer ID, when available.** macOS
   Sequoia keys TCC grants to *Bundle ID + Team ID*. Ad-hoc signing
   has an empty Team ID, so each rebuild's CDHash is a fresh identity
   and prompts return on every build. A real cert (even the free
   "Apple Development" cert Xcode auto-generates from an Apple ID)
   provides a stable Team ID and grants persist.
2. **Ad-hoc as fallback** — for first-time setup before any cert
   exists. Prompts will repeat per rebuild; this is expected.
3. **No `--options runtime`.** Hardened runtime + ad-hoc + no
   entitlements file silently breaks Calendar TCC on macOS Sequoia:
   `requestFullAccessToEvents()` returns `false` without ever
   showing the system dialog. We dropped hardened runtime from the
   ad-hoc path; it goes back in only if/when we add a real
   entitlements file for notarised distribution.

The script also writes the Info.plist with all four
`*UsageDescription` strings — required for the prompt to fire at all.

## How tools consult the authority

A tool that needs a permission queries `services.permissions.current(.calendar)`
(or whichever) and either:

- proceeds (`.granted`),
- asks the user once (`.notDetermined` → call `services.permissions.request(.calendar)`),
- returns a structured "permission needed" error to the LLM
  (`.denied` / `.limited` / `.restricted`).

The LLM sees a clean error message it can render to the user ("Rocky
not see calendar. Permission needed."); the user's intent isn't lost
in a silent failure.

## See also

- `decisions/0002-rocky-app.md` — why Rocky is a Swift macOS app and
  therefore inherits TCC.
- `concepts/voice-pipeline.md` — Microphone + Speech Recognition gate
  the listen pipeline.
- `concepts/tools-registry.md` — Calendar / Location are tool-side
  consumers.
