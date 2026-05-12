# Blink iOS Wiki Schema

This is the wiki for the **Blink iOS** terminal fork in this repo. It's a small
project-local knowledge base that captures **non-derivable** facts from dev
sessions: root causes, design tradeoffs, platform gotchas, escape-rule traps —
anything you can't reconstruct by reading `git log` or the code.

## Layout

Flat. One topic per file at `wiki/<slug>.md`. No subdirectories.

- `wiki/CLAUDE.md` — this schema (you're reading it)
- `wiki/index.md` — catalog: every page listed with a one-line hook
- `wiki/log.md` — append-only session log (`## [YYYY-MM-DD] <op> | <subject>`)
- `wiki/<slug>.md` — content pages

## Page types

| Type | When to write | Body shape |
|---|---|---|
| `entity` | A concrete subsystem / module / component | What it is, where it lives, the *why* behind its current shape, gotchas |
| `concept` | A non-trivial idea / technique / platform behavior that bites more than once | Definition, when it bites, how to avoid, examples |
| `note` | Loose observation worth saving but doesn't fit above | Free form, keep it short |

## Frontmatter

```yaml
---
title: <page title>
type: entity | concept | note
created: YYYY-MM-DD
updated: YYYY-MM-DD
---
```

## Link style

Markdown links: `[text](page-slug.md)`. Not `[[wikilinks]]`.

## Non-derivable gate

Before writing each paragraph, ask:

> Could a future session derive this from `git log`, the code, the global
> `~/.claude/CLAUDE.md`, the memory dir, or an existing wiki page?

If **yes**, don't write it. The wiki bloats fast if every session writes a
play-by-play. The valuable content is *root causes* and *traps that aren't
obvious from reading the source*.

## Workflow

- **handoff** at end of a substantive session: write/extend pages, update
  `index.md`, append to `log.md`, commit per scope, push.
- **snapshot** mid-session before `/compact`: write the deltas only, log
  one line, produce the `/compact` instruction, don't push by default.

Use the [wiki-handoff skill](https://github.com/anthropics/claude-skills)
to drive both.
