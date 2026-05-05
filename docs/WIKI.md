# Wiki schema and conventions

This document tells Claude how to operate the wiki. Read it before any ingest, query, or lint task.

## Layers

1. **Raw sources** — external docs, repos, the web. Immutable from Claude's perspective.
2. **Wiki pages** (this directory) — Claude-authored markdown. Synthesis, not duplication.
3. **Schema** — this file plus the project-root `CLAUDE.md`.

## Directory layout

```
docs/
├── README.md           — human-facing entry
├── WIKI.md             — this file
├── index.md            — page catalog (always current)
├── log.md              — chronological log
├── concepts/           — cross-cutting concepts
├── reference/          — factual lookups
├── workflows/          — how-tos
├── patterns/           — reusable code patterns
├── sources/            — per-source notes
└── decisions/          — ADRs, numbered 0001-, 0002-, …
```

## Page conventions

Every page starts with YAML frontmatter:

```yaml
---
title: <human-readable title>
type: concept | reference | workflow | pattern | source | decision
status: current | draft | superseded
last_updated: YYYY-MM-DD
sources:
  - sources/<file>.md     # or external URLs
tags:
  - reachy-mini-wireless
  - <other tags>
---
```

After the frontmatter:

- **One H1** matching the title.
- **Synthesis, not transcription.** Don't duplicate raw docs. Distill, structure, cross-reference.
- **Code blocks** for any executable snippet. Always tag the language.
- **Standard markdown relative links** (`[motion](../concepts/motion-philosophy.md)`), not Obsidian `[[…]]` — these render everywhere (GitHub, VS Code, plain text).
- **Cite sources** in frontmatter and inline when a fact is non-obvious.
- **No fabrication.** If a fact isn't in a source, mark it TODO and log the gap.

## Operations

### Ingest

When the user gives Claude a new source (URL, file, conversation):

1. Read the source.
2. Summarize key takeaways with the user. Confirm interpretation.
3. Create or update a `sources/<name>.md` page with the summary, key URLs, and what was extracted.
4. Update or create the relevant `concepts/`, `reference/`, `workflows/`, or `patterns/` pages.
5. Update `index.md` if pages were added or renamed.
6. Append a one-line entry to `log.md`.

A single source typically touches 3–10 wiki pages. Quality over breadth — partial updates are OK and should be flagged in the log.

### Query

When the user asks a question:

1. Read `index.md`.
2. Drill into the most relevant pages. Follow links across pages.
3. Answer with citations to the wiki pages used.
4. If the answer is novel synthesis (not just a lookup), file it back into the wiki — either as a new page or as an update to an existing one.

### Lint

When asked to health-check the wiki:

1. **Contradictions** — facts that disagree across pages.
2. **Stale claims** — versions, file paths, or behaviors that may have changed; verify against the latest source.
3. **Orphans** — pages with no inbound links from `index.md` or other pages.
4. **Gaps** — concepts referenced but lacking their own page.
5. **Broken links** — both internal and external.

Report findings, propose fixes, apply with user approval.

## `index.md` format

Grouped by category. Each entry: `- [Title](path) — one-line summary`. Keep summaries under 120 chars. Maintain a separate "Open gaps" section listing known un-ingested items.

## `log.md` format

Append-only. Each entry uses a parseable header so you can run `grep "^## \[" log.md | tail -20` to see the recent timeline:

```
## [YYYY-MM-DD] <op> | <subject>

- bullet 1
- bullet 2
```

`<op>` is one of: `init`, `ingest`, `query`, `lint`, `decision`, `code`.

## Don'ts

- Don't paste raw docs verbatim. Synthesize.
- Don't fabricate. If a fact isn't in a source, say so explicitly — mark unknowns as TODO in the log.
- Don't let pages drift. When you learn something new, update the wiki *before* finishing the conversation.
- Don't create empty placeholder pages. List the gap in `index.md` and `log.md` instead.
- Don't bloat. A page that's not referenced from anywhere is a smell.
