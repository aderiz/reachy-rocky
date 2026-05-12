---
title: Telemetry pipeline — LogBus, TelemetryEvent, MomentFeed
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/Telemetry/LogBus.swift
  - Sources/Telemetry/TelemetryEvent.swift
  - Sources/Telemetry/MomentFeed.swift
  - Sources/Telemetry/Moment.swift
tags: [telemetry, observability, logbus, moments, inspector]
---

# Telemetry pipeline

Every subsystem publishes structured events to a single bus.
Downstream consumers (the Inspector → Logs view, the activity
moment-strip on the portrait, sidecar restart logic) all read from
the same source. Three pieces:

```
sources              transport         consumers
─────────            ─────────         ─────────
voice                              ┌─▶ LogsView (raw event row)
brain                              │
sidecars     ─▶  LogBus  ─▶ pubsub ┼─▶ MomentFeed ─▶ recentMoments
robot link                         │     (coalesce + classify)
battery                            └─▶ activity strip + ActivityTab
…                                
```

## `LogBus` — the bus

`Sources/Telemetry/LogBus.swift:8` — a `public actor` with one
publisher (`publish(_:)`) and an `AsyncStream` per subscriber via
`subscribe()`. Subscribers receive `TimestampedEvent` envelopes in
the order they were published. New subscribers don't get backfill;
they see events from the moment they subscribe.

Bookkeeping is intentionally bounded — the bus buffers a small
window per subscriber (`.bufferingNewest(...)`) and drops older
events on overflow. The Inspector's Raw tab is the one consumer
that wants the full firehose; everything else aggregates.

## `TelemetryEvent` — the closed-set taxonomy

`Sources/Telemetry/TelemetryEvent.swift:8` — every event type Rocky
emits. The case list is the authoritative catalogue:

| Group | Cases |
|---|---|
| Motion | `motorCommand`, `motorState`, `stateStream`, `daemonStatus`, `robotLink` |
| Perception | `faceDetection`, `faceTarget` |
| Voice | `vadSegment`, `sttPartial`, `sttFinal`, `wakeMatch`, `conversationWindow`, `addressFilterAccept`, `addressFilterDrop`, `ttsRequest`, `ttsChunk` |
| Cognition | `llmRequest`, `llmChunk`, `llmToolCall`, `toolInvocation` |
| Sidecars | `sidecarLog`, `sidecarState` |
| Errors | `error(scope:message:recoverable:)` |

**Adding a case here is an explicit decision.** Every consumer
that switches over `TelemetryEvent` (LogsView, MomentFeed) has to
be updated in lock-step — the Swift compiler enforces it via
switch exhaustiveness, which catches drift at build time.

Three supporting enums:

- `MotionSource` — `user / face / tool / emotion`. Categorises
  motor commands by who issued them.
- `ConversationTransition` — `opened / extended / closed`. Maps
  to the WakeFilter state machine.
- `LogLevel` — `trace / debug / info / warn / error`, with a
  numeric ordering for filtering.

`TimestampedEvent` (`TelemetryEvent.swift:75`) bundles the event
with `Date` capture-time. Subscribers receive these, not raw
events.

## `MomentFeed` — narrative coalescence

The raw event stream is too detailed for the Activity tab. The
user wants moments like *"Rocky heard 'what time is it'"* and
*"Rocky said 'twelve thirty-four'"* — not 87 individual
`vadSegment` / `sttPartial` / `llmChunk` events.

`Sources/Telemetry/MomentFeed.swift:25` is a `public actor` that
consumes the bus and produces `Moment` objects on a separate
`AsyncStream`. Material coalescing rules:

**STT → wake-match coalescence.** An `sttFinal` event alone could
mean either "Rocky heard the user" OR "Rocky heard ambient
chatter". The follow-up `wakeMatch` (if any) tells us it was
addressed. So `sttFinal` is held for 100 ms; if a matching
`wakeMatch` arrives, emit `userSaid`. Otherwise emit `rockyHeard`
(quieter category).

**Brain turn aggregation.** `llmRequest` starts the buffer.
`llmChunk` events append to `pendingAssistantText`. `llmToolCall`
events build `pendingAssistantTools`. After a quiet window, all
three collapse into one `rockySaid(text:tools:)` moment.

**Tool-only invocations.** A `toolInvocation` outside an active
brain turn (e.g. fired by FastPath) emits a standalone `toolUsed`
moment.

**Face presence.** `faceDetection` events for the same person
within `faceRediscoveryWindow` are de-duplicated — only the
re-entry produces a `recognised(person:)` moment.

**Sidecar transitions.** Consecutive identical transitions within
`sidecarCoalesceWindow` collapse to one moment.

**Errors.** Each unique scope emits one moment; subsequent errors
in the same scope are suppressed until a recovery is detected.

Events explicitly *not* turned into moments (kept in the Raw tab
only): `motorCommand`, `motorState`, `stateStream`, `daemonStatus`,
`robotLink`, `faceTarget`, `vadSegment`, `sttPartial`,
`conversationWindow`, `ttsRequest`, `ttsChunk`, `sidecarLog`,
`addressFilterAccept`, `addressFilterDrop`.

## `Moment` — what the UI renders

`Sources/Telemetry/Moment.swift:18` — a Sendable Identifiable
struct with `timestamp` + `Kind`. Material `Kind` cases:

- `.userSaid(text:)` — wake-matched user utterance.
- `.rockyHeard(text:)` — STT-only, not wake-matched.
- `.rockySaid(text:tools:)` — assistant turn.
- `.recognised(person:)` — face appeared.
- `.toolUsed(name:summary:)` — stand-alone tool fire.
- `.sidecarChanged(name:transition:)` — sidecar lifecycle.
- `.errorOccurred(scope:message:)` — recoverable error.

`Moment.Category` (`Moment.swift:112`) gives each kind a category
key for filter chips: `you / rocky / face / tool / sidecar /
error`.

`AppServices.recentMoments` is the `@Observable` mirror of the
`MomentFeed` output stream — the activity strip and ActivityTab
both read from it.

## Subscriber etiquette

Bus subscribers run on detached `Task`s so they don't block the
main actor. Standard shape:

```swift
let bus = self.logBus
Task { [weak self] in
    for await event in await bus.subscribe() {
        await self?.handleEvent(event)
    }
}
```

If you need to emit from off-actor code, just `await
logBus.publish(.someEvent(...))` — `LogBus` is an actor, it
handles the concurrency.

## Adding a new event type

1. Add a `case .yourEvent(params)` to `TelemetryEvent`.
2. Update `LogsView.classify(...)` to render it.
3. Update `MomentFeed.ingest(...)` to either coalesce it into a
   `Moment` or add it to the "don't turn into moments" list at
   the bottom of the switch.
4. Build — Swift's exhaustiveness check will flag any consumer
   you missed.

The plumbing is deliberately strict so partial coverage breaks
the build rather than silently dropping the event.

## See also

- [App Services](app-services.md) — owns the `logBus`,
  `momentFeed`, and `recentMoments` plumbing.
- [Cockpit design](cockpit-design.md) — the Activity tab + portrait
  strip surfaces.
- [AddressFilter](address-filter.md) — emits `addressFilterAccept`
  / `addressFilterDrop` for diagnostic visibility.
