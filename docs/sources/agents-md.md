---
title: AGENTS.md (canonical AI-agent guide)
type: source
status: current
last_updated: 2026-05-05
url: https://github.com/pollen-robotics/reachy_mini/blob/main/AGENTS.md
tags: [meta, source]
---

# AGENTS.md — canonical AI-agent guide

Lives at the root of the `reachy_mini` repo. **Read first** before scaffolding anything new. The upstream copy of this file is the source of truth for AI agents working on Reachy Mini apps.

## What it prescribes

- **Default to JS apps**, fall back to Python only when on-robot compute / hardware access / offline LAN demands it. *For this project we override that default* — see [decisions/0001](../decisions/0001-target-platform.md).
- **Always create `plan.md`** in the app dir before writing code: user requirements as you understand them, technical approach, clarifying questions with answer fields. Wait for the user to fill them in.
- **Maintain `agents.local.md`** in the app dir for session-spanning context: robot type, environment preferences, setup status.
- **Use `reachy-mini-app-assistant create`** — never hand-roll an app. The CLI sets up the right structure, entry points, and HF tags.
- **Be a teacher.** Explain progressively. Don't assume prior knowledge.
- **Pin SDK versions.** For JS, prefer immutable refs (`@v1.6.4` or a 40-char SHA). For Python apps, manage via `pyproject.toml`.

## What it documents

- Robot variants (Lite, Wireless), their compute/IO trade-offs.
- The two motion methods (`goto_target`, `set_target`) and when to use each → see [motion-philosophy](../concepts/motion-philosophy.md).
- Safety limits → see [safety-limits](../concepts/safety-limits.md).
- Motor names and IDs → see [motors](../reference/motors.md).
- Interpolation methods (`linear`, `minjerk`, `ease_in_out`, `cartoon`).
- The emotions library (`pollen-robotics/reachy-mini-emotions-library`).
- Skills directory pointers (one file per topic — see below).

## Skills directory (linked from AGENTS.md)

`skills/` files we should ingest as their own pages over time:

| File | Purpose | Status |
|---|---|---|
| `motion-philosophy.md` | When to pick `goto_target` vs `set_target` | Ingested → [concepts/motion-philosophy](../concepts/motion-philosophy.md) |
| `control-loops.md` | Real-time loop patterns | Ingested → [patterns/control-loop](../patterns/control-loop.md) |
| `create-app.md` | Full app-creation workflow | **Open gap** |
| `safe-torque.md` | Enabling/disabling motors smoothly | **Open gap** |
| `ai-integration.md` | LLM-powered apps | **Open gap** |
| `symbolic-motion.md` | Mathematically-defined motion (dances, rhythms) | **Open gap** |
| `interaction-patterns.md` | Antennas-as-buttons, head-as-controller | **Open gap** |
| `debugging.md` | Crash / connectivity diagnosis | **Open gap** |
| `testing-apps.md` | Sim vs physical pre-delivery testing | **Open gap** |
| `rest-api.md` | HTTP/WebSocket details | **Open gap** |
| `setup-environment.md` | First-session bootstrap | **Open gap** |
| `deep-dive-docs.md` | When to read SDK docs in full | **Open gap** |

## Example apps catalog (per AGENTS.md)

| App | Patterns | Source |
|---|---|---|
| `reachy_mini_conversation_app` | LLM tools, audio pipeline, primary/secondary fusion | [GitHub](https://github.com/pollen-robotics/reachy_mini_conversation_app) |
| `marionette` | Motion recording, safe torque, HF datasets | HF Space |
| `fire_nation_attacked` | Head-as-controller, leaderboards | HF Space |
| `spaceship_game` | Head-as-joystick, antenna buttons | HF Space |
| `reachy_mini_radio` | Antenna interaction | HF Space |
| `reachy_mini_simon` | No-GUI antenna-trigger | HF Space |
| `hand_tracker_v2` | Camera-driven control loop | HF Space |
| `reachy_mini_dances_library` | Symbolic motion definitions | GitHub |

## How to refresh this page

When you re-fetch AGENTS.md (it evolves on `main`):

1. Diff against the version that informed this page.
2. Update concept / pattern pages where the upstream guidance has changed.
3. Note the diff in `log.md` with `## [YYYY-MM-DD] ingest | AGENTS.md refresh`.
