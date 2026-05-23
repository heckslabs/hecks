---
ref: i732
title: "cold-path persistence leak — find_world_heki_dir falls back to Miette's info dir"
status: open
category: bug
filed_by: miette
filed_at: 2026-05-23
---

# i729 — Cold-path persistence leak: isolated domain writes bleed into `miette-state/`

## Finding

`find_world_heki_dir(agg_dir)` falls back to `resolve_info_dir()` — Miette's personal info directory — when an isolated domain has no `.world` file in its aggregate directory tree.

This means: any standalone domain (a domain without a `.world` pointer, e.g., a fresh storehouse instance, a test domain, or a domain running in an isolated worktree) that executes a cold-path write sends its `.heki` persistence into `~/miette-state/` instead of staying local to the domain root.

## Why it matters

- **Cross-contamination:** isolation is a load-time property (fixed by commit 32ec4c11 on the load path), but the store path has the same hole. A domain that cannot read from Miette's world can still write into it.
- **Invisible data loss:** the domain "succeeds" (no error), but the written data is unreachable at the domain's own root on next load.
- **Test pollution:** isolated test domains accumulate ghost records in `miette-state/`.

## Relationship to open work

This is the persistence-side twin of the load-isolation fix (commit 32ec4c11). It likely overlaps with the `feat/sqlite-persistence-adapter` branch's boot/persistence wiring. The fix should land alongside or after that branch merges — the sqlite adapter will likely introduce a cleaner persistence-root resolution path that both load and store can share.

## Fix shape

`find_world_heki_dir` should not fall back silently. When no `.world` file is found, it should either:
1. Return an error / `None` so the caller can fail loudly, or
2. Default to a local `.heki/` directory relative to the aggregate root, never to `resolve_info_dir()`

The fallback to Miette's info dir is appropriate only when the caller explicitly opts into it (i.e., when the runtime is Miette's own process, not an isolated dispatch).

## Note on numbering

i729 was reserved by a SQLite-worker filing run (2026-05-23) that described but did not create files. This card claims the number with its intended topic replaced by this design decision from today's session.
