# Reachy Mini Wireless — Project Wiki

This is an LLM-maintained knowledge base for building Python apps on Reachy Mini Wireless.

It follows the **LLM Wiki pattern**: an LLM agent (Claude) reads sources, synthesizes them into interlinked markdown pages, and maintains the whole thing as the project grows. The wiki sits between you and the raw docs — instead of re-deriving knowledge on every question, the synthesis is built once and kept current.

## How to read this

- **`index.md`** — catalog of every page, organized by category.
- **`log.md`** — chronological record of ingests, queries, and lint passes.
- **`concepts/`** — cross-cutting concepts (architecture, motion philosophy, coordinate frames…).
- **`reference/`** — facts and lookups (hardware specs, SDK API, motors, glossary).
- **`workflows/`** — how-tos (dev loop, app creation, run and debug).
- **`patterns/`** — reusable code patterns extracted from official examples.
- **`sources/`** — annotated summaries of each external source we've read.
- **`decisions/`** — project-specific decisions, ADR-style.

## How it stays current

Claude follows `WIKI.md` to ingest new sources, answer questions, and lint the wiki. Every meaningful interaction can produce wiki updates. Open `log.md` for a timeline.

## How to use it as a human

Browse normally. Open the file tree in your editor. Follow links. When you want to learn something new, ask Claude to ingest it — Claude reads the source, summarizes it, and integrates it across the relevant pages.
