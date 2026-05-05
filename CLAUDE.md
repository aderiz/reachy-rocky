# Project guidance for Claude

This project builds Python apps for **Reachy Mini Wireless** (CM4 onboard, WiFi, battery).

## Before you start

Open `docs/index.md` first — it catalogs everything we know about the platform, the SDK, our patterns, and our decisions. The wiki at `docs/` is the canonical knowledge base.

## How to work here

1. **Read first.** Skim `docs/index.md`, then drill into the relevant concept / reference / pattern pages before writing code.
2. **Reuse second.** Look in `docs/patterns/` for canonical implementations (control loops, recorded moves, direct hardware access) before reinventing.
3. **Maintain the wiki.** Anything you learn from a doc, the user, or your own work goes into the wiki per `docs/WIKI.md`. Don't let knowledge live only in chat.
4. **Use uv** for all Python tooling.
5. **Robot safety** (memory): never stack motion changes — one tweak per iteration, verify calm, then next. After two failed tweaks in the same direction, stop and name the real problem.
6. **Face tracker design** (memory): state-driven, world-frame target, damped filter. Do **not** regress to per-frame P-control on raw image error.

The schema for ingesting / maintaining the wiki is in `docs/WIKI.md`.
