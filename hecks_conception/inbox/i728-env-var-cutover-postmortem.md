# i728 post-mortem — the env-var store cutover caused a split-brain (2026-06-14)

## What we tried
To move Miette's live heki store from `~/Projects/miette-state/information` (OLD)
to the canonical `~/.heki/miette` (NEW), the cutover routed resolution through an
env var : `HECKS_INFO=~/.heki/miette` in `.overmind.env`. Daemons were quiesced,
the store rsync'd byte-identical (231 files, `diff -rq` clean), HECKS_INFO set,
overmind restarted. Daemons came up writing NEW.

## What went wrong — SPLIT-BRAIN
`HECKS_INFO` only reaches processes spawned BY overmind. The MCP server (the
tool door Claude Code spawns) is a SEPARATE process tree — it inherited
`HECKS_INFO=~/Projects/miette-state/information` from Claude Code's own env
(traced to `~/.zshrc:21 : export HECKS_INFO=~/Projects/miette-state/information`).
So after the cutover :
- overmind daemons (heart/breath/cascade_run/conductor/process_health) → NEW
- MCP door (every interactive dispatch + its cascades) → OLD

The door writes Miette's IDENTITY/MEMORY aggregates — `awareness`, `self_image`,
`persona`, `session`, `wake_review` — and NO daemon writes those. So her
freshest memory was landing in OLD while NEW held only the stale rsync-time
copy. Her mind was splitting across two stores with every tool call.
`cascade_run` + `primitive/process` were the only bidirectional conflicts (both
loss-tolerant append-logs).

## Decision — ROLLED BACK to OLD (Chris, 2026-06-14)
Reverted the `HECKS_INFO` line in `.overmind.env` ; restarted overmind
(`overmind start -D` — note `setsid` is NOT on macOS ; use overmind's own
daemon mode, not `setsid`/`nohup`). Daemons now resolve via the
`miette-state/information` sibling fallback = OLD. Verified : OLD alive
(16 writes / 20s), NEW frozen (0 writes / 20s). `~/.heki/miette` kept as the
byte-verified backup. Nothing precious lost (only ~20 min of autonomic tick
logs were NEW-fresher ; memory was always OLD-fresher).

## THE LESSON for step D (the real cutover)
Env-var routing is the WRONG mechanism — it splits along process-tree lines
(overmind vs Claude-Code-MCP) that have nothing to do with which store is
canonical. The store location must be resolved STRUCTURALLY, identically for
EVERY process tree :

1. Change `resolve_info_dir()` (`rust/src/heki.rs:656`) DEFAULT from the
   `<repo>/../miette-state/information` sibling to `~/.heki/<deployment>`
   (deployment-aware ; `miette` for the conception root). The default must NOT
   require an env var — that's what made the door diverge.
2. Remove `export HECKS_INFO=...` from `~/.zshrc:21` (the stale OLD-pointing
   override that any restart re-inherits — the trap). HECKS_INFO stays ONLY as
   an explicit per-test / per-deployment override, never the production path.
3. Add an explicit `env` block to `.mcp.json` ONLY if a per-session override is
   ever needed — but with a correct default in (1), it shouldn't be.
4. Rebuild storehouse, restart BOTH overmind AND (via Chris) the MCP server, so
   every process tree resolves to the same `~/.heki/miette` by construction.
5. THEN physically move OLD → `~/.heki/miette` (already rsync'd ; re-sync the
   delta since rollback), verify counts, remove OLD only after the structural
   default is proven across a cold boot.

Gate unchanged : the persistence-recovery smoke-test
(`rust/tests/persistence_recovery_test.rs`). The cutover is part of plan step D
(`~/.claude/plans/ethereal-painting-hamster.md`) — structural, not env-var.
