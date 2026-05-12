---
title: FastPath — sub-second time-to-first-word
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Cognition/FastPath.swift
  - Sources/Rocky/AppServices.swift
tags: [fast-path, cognition, intent-matching, latency]
---

# FastPath

A regex-based intent matcher that **bypasses the brain** for
trivially common queries. The user says "what time is it" and
Rocky speaks the answer back in under a second — no LLM round-
trip, no token generation, no streaming.

`Sources/Cognition/FastPath.swift:22` — `public actor FastPath`.

## Why it exists

A typical brain turn through MLX-VLM takes 2-4 seconds for the
first audible word (depends on model + cache hit). For
conversational queries the user already knows the answer shape —
"what time is it", "what's the weather", "remember that I prefer
oat milk" — paying brain-turn latency is overkill. FastPath
short-circuits these with a deterministic pattern match + direct
tool dispatch.

When a query *doesn't* match any FastPath intent, the full brain
turn runs as normal.

## Wiring

`CognitionEngine.setFastPath(_:)` registers the matcher. Before
each brain turn, `CognitionEngine` checks the FastPath first:

```
sendUserText(text)
    ├── FastPath.match(text)?
    │       ├── matched ──▶ FastPath.handle(...) ──▶ TTS, log, return
    │       └── no match
    └── full brain turn
```

If the FastPath handler returns nil (matched but no result —
e.g. memory recall came back empty), the full brain turn runs as
fallback. If it returns a string, that's what Rocky says.

## Intents shipped

`FastPath.Intent` (`FastPath.swift:35`) is the closed set.
`AppServices.registerInitialTools()` + `Self.makeFastPath(...)`
wire the handlers:

| Intent | Example utterance | Handler |
|---|---|---|
| `.time` | "what time is it?" | Calls `get_time` tool, returns the narrative. |
| `.weather` | "what's the weather?" | Calls `get_weather` tool (with optional location capture from "weather in Berlin"). |
| `.calendar` | "what's on tomorrow?" | Captures `tomorrow / this week / next week` → `days_ahead` → `get_calendar`. |
| `.search` | "search for octopuses" | Calls `search_web`. |
| `.remember` | "remember that I prefer oat milk" | Captures the body → `add_memory`. |
| `.greeting` | "hello rocky", "hi" | Direct response (no tool call). |

Each handler is an `async throws (FastPathMatch) -> String?`
closure registered via `register(_:handler:)`. The match payload
carries:

- `intent` — which one fired.
- `groups: [String]` — regex capture groups (e.g. the captured
  location for weather).
- `utterance: String` — the full original text.

## Pattern shape

Each intent has one or more `Pattern`s — a regex anchored at the
start of the utterance, ignoring case + leading wake-word
prefixes. `Pattern.init(intent:pattern:)` (`FastPath.swift:45`)
compiles to `NSRegularExpression`.

Example shape (from `makeFastPath` in `AppServices.swift`):

```
weather:
    ^(?:what'?s|what is|tell me|how('s| is)?)\s+(?:the\s+)?weather
        (?:\s+(?:in|for)\s+(.+))?$
```

The optional second capture group captures the location ("in
Berlin"). A miss simply means the next pattern is tried; if
nothing matches, the full brain turn runs.

## Result handling

The handler's returned string is treated as the answer text:

1. Logged to `LogBus` as a synthetic assistant turn so the
   transcript shows it.
2. Sent to TTS via `RobotTTS.speak(...)`.
3. The originating `sttFinal` → `wakeMatch` events are paired with
   the response so MomentFeed emits a clean `userSaid →
   rockySaid` moment pair.

The brain does not see the utterance at all — `cognition.send`
returns early once FastPath matches.

## End-of-turn behaviour

FastPath responses bypass the brain's tool-loop, so the
post-`say` "end the turn" rule documented in CLAUDE.md doesn't
apply to FastPath — there's no brain that could loop back.

## When *not* to use FastPath

If a query needs:

- Multi-turn context (e.g. "remind me what I just said")
- Tool composition (e.g. "if it's raining, set a 10 minute timer")
- Anything that varies based on memory recall content

…it should go through the brain. FastPath is for queries whose
answer shape is fixed at compile time.

Adding a new intent is intentionally a thoughtful step: register
a new `Intent` case, write the regex, write the handler, add to
the catalogue. Don't do it for one-off shapes.

## Telemetry

A FastPath match emits a `toolInvocation` event for the underlying
tool (if any) but doesn't emit `llmRequest` / `llmChunk` events —
the brain wasn't called. The LogsView and Activity tab treat
FastPath responses as standalone tool moments, not as brain
turns.

## See also

- [Tools registry](tools-registry.md) — the tools FastPath
  dispatches to.
- [App Services](app-services.md) — `start()`'s wiring of
  `makeFastPath` + `setFastPath`.
- [Voice / listen pipeline](voice-pipeline.md) — the upstream
  path that produces the user-text FastPath examines.
