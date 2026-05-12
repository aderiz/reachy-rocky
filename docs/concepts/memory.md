---
title: Memory — mempalace + recall_memory
type: concept
status: current
last_updated: 2026-05-12
sources:
  - Sidecars/mempalace/rocky_mempalace/runner.py
  - Sources/Memory/MemoryService.swift
  - Sources/Rocky/Tools/RecallMemoryTool.swift
  - Sources/Cognition/CognitionEngine.swift
tags: [memory, mempalace, chromadb, recall, persona]
---

# Memory

Rocky uses **`mempalace`** — a ChromaDB-backed semantic memory
store — through a Python sidecar at `Sidecars/mempalace/`. Two
distinct use paths:

1. **Auto-recall before every brain turn.** When
   `settings.memoryRecallEnabled` is true (default), every user
   prompt also pulls the top-K matches from the palace and the
   matches are injected into the system message before the brain
   sees them. This is what gives Rocky "remembers your name"
   continuity across launches.
2. **Explicit `recall_memory` tool.** The brain can call
   `recall_memory(query, k)` mid-turn to fetch additional context
   when auto-recall didn't surface what it needed.

Writes happen automatically — every (user, assistant) exchange is
written back so the next launch has fuller context.

## Sidecar — what it does

`Sidecars/mempalace/rocky_mempalace/runner.py` wraps mempalace
behind the line-JSON sidecar contract. RPC methods
(`runner.py:269`):

| Method | Purpose |
|---|---|
| `init_palace()` | Open the ChromaDB collection. Idempotent. |
| `add(role, text, [meta])` | Write a drawer. `role` is `user` / `assistant` / `tool`. mempalace hashes the content for dedup. |
| `recall(query, [k])` | Semantic search. Returns `{hits: [{text, role, score, ts}]}`. |
| `count()` | How many drawers exist. Used by the Inspector → Status row. |
| `forget_all()` | Wipe the entire collection. Used by Settings → Memory → "Forget everything". |
| `health()` | Liveness probe. |

The sidecar is started by `AppServices.start()` (`AppServices.swift:start`)
— best-effort. If the venv isn't built, `memory.start()` fails
cleanly and recall is skipped on subsequent turns; writes also no-op.

## Storage

The collection lives at
`~/Library/Application Support/Rocky/Memory/`. Path is set by
`MEMPALACE_PALACE_PATH` in the sidecar manifest. Wing / room are
configurable via `ROCKY_MEMORY_WING` / `ROCKY_MEMORY_ROOM`
environment variables (default `rocky` / `conversation`). All
drawers go into the same wing+room; mempalace handles dedup
internally based on content hash.

To wipe and start fresh:

```bash
rm -rf "$HOME/Library/Application Support/Rocky/Memory"
```

The sidecar will recreate the collection on next launch.

## Stdout protection — non-obvious gotcha

mempalace internally executes `os.dup2(2, 1)` at import time — an
fd-level redirect that points fd 1 (stdout) at fd 2 (stderr) so
any `print()` inside the library lands on stderr instead of the
caller's stdout. This protects callers from mempalace's chatter,
but it would also break our line-JSON wire if we used `sys.stdout`
naively.

`runner.py:50-60` works around it: we save the original stdout fd
via `os.dup(1)` **before** importing mempalace, then write our
envelopes directly to that saved fd via `os.write`. This bypasses
both `sys.stdout` rebinding and fd-level `dup2`. mempalace's
internal `print()` calls still go to stderr; our wire stays clean.

If you ever need to write something else to stdout from the
mempalace sidecar, write to `_REAL_STDOUT_FD` directly — don't
use `sys.stdout` / `print()`, those land on stderr.

## CognitionEngine integration

`CognitionEngine` (`Sources/Cognition/CognitionEngine.swift`) calls
`MemoryService.recall(query, k:)` before each brain turn when
auto-recall is enabled. The hits are formatted as
`[role @ ts] body` lines and injected into the system message,
prefixed by a soft envelope that explicitly says memories are real
and may be cited. (The envelope was tightened in commit
`2876fc3` because the brain was previously denying that it
remembered anything.)

The `RecallMemoryTool` (`Sources/Rocky/Tools/RecallMemoryTool.swift`)
exposes recall as a brain-callable tool — `recall_memory(query, k)`
— for mid-turn lookup when the initial auto-recall didn't surface
what the brain needs.

## Settings

| Field | Default | Effect |
|---|---|---|
| `memoryRecallEnabled` | `true` | Master switch for auto-recall. When false, `recall(...)` is skipped before each turn; writes still happen so re-enabling later has full context. |
| `memoryTopK` | `5` | Drawers pulled per recall. 3–10 is sane. Lower keeps the prompt focused; higher gives more context at the cost of noise + tokens. |

## Drawer schema

Each drawer carries:

```
{
  "role": "user" | "assistant" | "tool",
  "text": "<content>",
  "ts": "<ISO8601>",
  "meta": { ... }   // optional, free-form
}
```

The Memory tab in the Inspector renders the most recent drawers in
chronological order so the user can see what Rocky has stored.

## Failure modes

- **Venv not installed** — `services.memory.start()` raises;
  `AppServices` catches and logs a one-time error. Auto-recall is
  skipped on every turn; the `recall_memory` tool returns
  `{error: "memory unavailable"}`.
- **ChromaDB collection corrupted** — call `forget_all()` from the
  Settings tab, or `rm -rf Memory/` from disk. The sidecar
  recreates the collection on next call.
- **Slow recall under heavy load** — mempalace recall is single-
  threaded inside the sidecar; bursts of `recall_memory` tool
  calls serialise. CognitionEngine awaits the result, so brain
  turns block on recall latency.

## See also

- [Tools registry](tools-registry.md) — where `recall_memory` is
  declared.
- [Sidecar convention](sidecar-convention.md) — the wire protocol
  the mempalace sidecar follows.
- [Application Support layout](../reference/application-support-layout.md)
  — where the ChromaDB collection lives on disk.
