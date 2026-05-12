---
title: Sidecar supervisor — restart policy + circuit breaker
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sources/SidecarHost/SidecarSupervisor.swift
  - Sources/SidecarHost/SidecarRuntime.swift
  - Sources/SidecarHost/JSONLineCodec.swift
tags: [sidecar, supervisor, reliability, circuit-breaker, restart]
---

# Sidecar supervisor

The runtime that owns every Python sidecar's process lifecycle —
spawning, restart-on-exit, and the circuit-breaker that prevents
hammering a chronically-failing sidecar.

`Sources/SidecarHost/SidecarSupervisor.swift:8` — `public actor`.
Sister doc: [sidecar-convention](sidecar-convention.md) describes
the wire protocol every sidecar speaks; this page covers what
happens when the wire goes wrong.

## Lifecycle

Each registered sidecar runs through these phases:

```
stopped ──start──▶ starting ──ready event──▶ ready
                       │                       │
                       │                       ├── exit / EOF ──▶ failing
                       │                       │
                       └── timeout ──▶ failing │
                                               │
failing  ── attempts < max ──▶ starting        │
failing  ── attempts >= max ──▶ circuitOpen ◀──┘
                                       │
                                       └── cooldown elapsed ──▶ stopped (eligible to start)
```

States are surfaced via `SidecarRuntime.state` as the `SidecarState`
enum: `.stopped`, `.starting`, `.ready`, `.failing(reason:)`,
`.circuitOpen(until:)`. `AppServices` mirrors each onto an
`@Observable` slot (`ttsSidecarState`, `brainSidecarState`,
`memorySidecarState`) so the Status panel can show health rows.

## Restart policy

Healthy lifecycle:

1. Supervisor starts the sidecar's subprocess (`uv run` or direct
   `python -m`).
2. Sidecar emits `{event: "ready"}` on stdout within
   `readyTimeoutS` (default 30 s; longer for the brain, which has
   to load weights).
3. Supervisor transitions to `.ready`. Stays there until exit.

Unhealthy lifecycle:

1. Sidecar exits / stdin EOF / `ready` event times out.
2. Supervisor records the failure, increments the `attempts`
   counter, and re-launches after a short backoff.
3. Backoff grows exponentially: 1 s, 2 s, 4 s, 8 s, capped.
4. After `maxAttempts` (typically 5), enter the circuit breaker.

## Circuit breaker

`SidecarSupervisor.swift:101` — `enterCircuitBreak(cooldownS:)`.

When a sidecar fails too often, the supervisor stops trying for
a fixed cooldown window (default 60 s). During cooldown:

- `runtime.state == .circuitOpen(until: <date>)`.
- `start(name:)` calls no-op until the cooldown passes.
- The Status panel shows "cooldown · Xs" so the user knows what's
  happening.

After cooldown the sidecar is eligible to start again from
`.stopped`. The attempts counter resets on a successful `ready`
event.

This pattern prevents two bad behaviours:

1. **Tight restart loops**. A sidecar with a syntax error or a
   missing dep would otherwise restart hundreds of times per
   minute, spam the bus, and make the user wait for a real fix.
2. **Daemon hammering**. Sidecars that hold connections to the
   bot's daemon could rapidly re-open + close on every restart,
   triggering the daemon's own rate limits.

The 60 s cooldown is empirical — long enough that the user has
time to read the error, short enough that recovering after a fix
doesn't feel like waiting forever.

## Wire protocol resilience

`Sources/SidecarHost/JSONLineCodec.swift` is the line-JSON
encoder/decoder both sides of the wire use. Three resilience
features:

**Non-JSON lines are tolerated.** Sidecars sometimes print to
stdout outside the protocol (e.g. mlx-vlm warnings during weight
load). The codec skips them silently; the warning is forwarded to
stderr so it still shows in Console.app but doesn't poison the
wire.

**Partial line accumulation.** If a write splits a JSON object
across two stdout writes, the codec buffers until a newline
arrives before parsing.

**Per-event error reporting.** A malformed JSON line emits a
`.error(scope: "sidecar.codec", ...)` event but doesn't kill the
sidecar — the next valid line is processed normally.

## Stderr mirroring

`SidecarHost` mirrors every sidecar's stderr to the parent app's
stderr (commit `e29c11b`). This makes sidecar log messages and
crash tracebacks visible in Console.app under the Rocky bundle
id, alongside the app's own logs. Essential during the v0.2
brain rebuild where the only signal was "the brain returned no
tokens" — stderr mirroring let us see the actual mlx-vlm
exception.

## Public API

```swift
let supervisor = SidecarSupervisor(logBus: bus)

supervisor.register(runtime: streamingTTSRuntime, name: "mlx-tts")
supervisor.register(runtime: brainRuntime, name: "brain")

try await supervisor.startAll()      // start every registered runtime
try await supervisor.start(name: "mlx-tts")  // start one
await supervisor.stop(name: "brain")          // graceful stop
await supervisor.stopAll()                    // shutdown
```

`SidecarSupervisor.defaultVenvDir(for: name)` is a nonisolated
helper returning
`~/Library/Application Support/Rocky/sidecars/<name>/.venv/` —
the canonical venv location every `setup.sh` writes to.

## Failure mode summary

| Symptom | Likely cause | Resolution |
|---|---|---|
| Sidecar stuck in `.circuitOpen` | 5+ consecutive failures | Read its stderr in Console.app; fix the root cause; the breaker resets after 60 s |
| Sidecar never reaches `.ready` | venv not built or wrong Python | `rm -rf ~/Library/Application\ Support/Rocky/sidecars/<n>/.venv && ./Sidecars/<n>/setup.sh` |
| `.ready` flickers to `.failing` mid-session | sidecar crashed mid-call | Check the request that triggered the crash; common cause is a malformed RPC param |
| `.starting` for >30 s then fails | model still downloading | Increase `readyTimeoutS` for that sidecar (brain often hits this on first cold launch with no HF cache) |

## See also

- [Sidecar convention](sidecar-convention.md) — wire protocol +
  manifest schema each sidecar must follow.
- [App Services](app-services.md) — how `SidecarRuntime`s get
  registered and started in `start()`.
- [Application Support layout](../reference/application-support-layout.md)
  — where venvs live on disk.
