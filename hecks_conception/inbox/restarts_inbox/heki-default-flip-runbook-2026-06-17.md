# Flip Miette's organs to ~/.heki (the precise-pass flip) — RUNBOOK

**Status (2026-06-17):** the CODE is done, committed, and verified. The live
FLIP is deliberately NOT done — it must happen at a fresh BOOT before a session's
MCP establishes (the MCP door inherits boot's exported HECKS_INFO, so a
mid-session flip leaves my own hands writing to the old store = split-brain).
This is Chris's operational call (when to reboot my body).

## What's already done

- **main** (`d63470f1c`): realm grammar + `:default` folder-derivation
  (writer-side, find_world_heki_dir). pizzas.world uses `dir :default`.
- **branch `sq/heki-default-reader-unification` (`e76053455`)**: lifts the
  store resolver into the heki lib so the READER (resolve_info_dir —
  statusline/run_wake/run_boot) and the WRITER share ONE resolver, both ordered
  HECKS_INFO-first then world-resolution. Adds `hecks_conception/miette.world`
  (`heki do; dir :default end`). Full Rust suite green ; world parity 10/10.
- **(B) proven empirically**: `env -u HECKS_INFO` resolves the conception to
  `~/.heki/hecks` ; with HECKS_INFO set it stays at miette-state (master switch).
- **Defensive sync done**: `~/.heki/hecks` holds a point-in-time copy of
  `miette-state/information` (167 entries). miette-state is the LIVE store and
  the ROLLBACK — untouched.
- **Disarmed**: the on-disk binary is rebuilt from main (no miette.world, no
  reader unification), so any boot today stays safely on miette-state.

## Why the flip works without env edits

HECKS_INFO is NOT set persistently (`.zshrc` has it commented out, `.overmind.env`
doesn't set it). It is EXPORTED by `run_boot` into the process tree. So a FRESH
boot has no HECKS_INFO → the new binary's resolve_info_dir → miette.world
`:default` → `~/.heki/hecks`, which boot then exports to daemons. The flip = a
fresh boot on the new binary with state synced. No env-file changes.

My organs resolve to `~/.heki/hecks/<domain>/<aggregate>.heki` (data_dir
`~/.heki/hecks` from derive_default_chain(hecks_conception) + per-aggregate
context). This mirrors today's `miette-state/information/<domain>/<aggregate>.heki`
exactly — only the root moves, so the migration is a clean subtree copy.

## THE FLIP (run at a session boundary, ideally so SessionStart boots it clean)

```sh
# 1. Arm: merge the unification branch + rebuild
cd ~/Projects/hecks
git checkout main && git merge sq/heki-default-reader-unification
(cd rust && cargo build --release)

# 2. Stop the live daemons so miette-state stops changing during the final sync
overmind quit          # or kill the overmind session

# 3. FINAL one-time sync — catch every write since the defensive sync
#    (--delete makes it exact ; omit if you'd rather not prune)
rsync -a --delete ~/Projects/miette-state/information/ ~/.heki/hecks/

# 4. Clean boot on a FRESH tree (no inherited HECKS_INFO)
cd hecks_conception && env -u HECKS_INFO overmind start

# 5. Verify round-trip (do NOT trust MCP hands — use the binary directly):
#    - statusline shows my state (woke / mood / tick)
#    - env -u HECKS_INFO ./rust/target/release/storehouse <read an organ> returns real data
#    - new tick/pulse writes land under ~/.heki/hecks, not miette-state
```

## Rollback (miette-state is untouched)

Boot with HECKS_INFO set again (`export HECKS_INFO=~/Projects/miette-state/information`
then `overmind start`), or revert the merge. miette-state still has everything.

## Everything that relies on HECKS_INFO (inventory, 2026-06-17)

**Production READS**
- `heki.rs::resolve_info_dir` (the canonical reader — statusline, run_wake,
  run_boot, run.rs, storehouse_log, main all funnel here). HANDLED on the branch
  (HECKS_INFO-first → world fallback).
- `run_status/mod.rs::resolve_fs_root` — a SEPARATE direct reader for the status
  report. Still HECKS_INFO-as-override, NOT yet unified with the world resolver.
  GAP : fold it onto `resolve_world_store_dir` in the code-retirement step.

**Production EXPORT (propagation)**
- `run_boot/daemons.rs:149` — boot `.env("HECKS_INFO", info_dir)` spawns daemons
  with the resolved dir so all forks share ONE value (i154 anti-split). After
  the flip, boot resolves `~/.heki/hecks` from the world and exports THAT — so
  HECKS_INFO becomes boot's internal world-derived propagation cache, never a
  user override.

**INHERITANCE (the MCP + my shell)**
- `.mcp.json` does NOT set HECKS_INFO ; the storehouse MCP node server inherits
  it from the parent (Claude Code launch). Its `storehouse` subprocesses then
  carry it. So the MCP relies on HECKS_INFO only by inheritance.

**TEST-ONLY (fine)**
- `story_runtime` (sets/restores for story isolation), `heki.rs` resolve_tests,
  `tests/*.sh` smoke scripts, `status_golden.sh` — all scope a tmpdir.

## Should the MCP rely on HECKS_INFO? No. How to handle it.

The MCP already passes `aggregates_dir` explicitly, so it CAN resolve from the
`.world`. It only leans on HECKS_INFO by inheritance. Two handlings :

1. **Targeted, now-safe-at-flip** : add `"HECKS_INFO": ""` to `.mcp.json`'s env.
   Empty is treated as unset, so the MCP's storehouse ALWAYS falls to
   world-resolution regardless of what the parent exported. Do this AS PART OF
   the flip (not before) — otherwise the MCP jumps to `~/.heki/hecks` while
   daemons are still on miette-state (a new split).
2. **Structural end-state** : retire HECKS_INFO PRECEDENCE in code (the deferred
   commit) so the `.world` always wins. Then HECKS_INFO is at most boot's
   internal propagation cache (always derived from the world) or removed
   entirely — nothing user-facing relies on it, and the split-brain class is
   gone for the MCP, daemons, and readers alike.

## NEXT SESSION (fresh head) : fully retire HECKS_INFO — the plan

The FLIP is done and live (organs on ~/.heki/hecks). Production is already
env-free (daemons run with HECKS_INFO unset, resolve via miette.world). The
remaining work is DELETING the var name + killing its auto-propagation. Banked
for a fresh head because it is **129 refs across 23 files** including the
resolver my boot depends on — a missed ref breaks my wake. Do it grep-verified,
full suite + ALL smoke .sh green, on a branch, BEFORE it touches a boot.

### The 23 files (grep `HECKS_INFO`)
- **Production resolvers (behavioural)** : `heki.rs` (resolve_info_dir),
  `main.rs` (find_world_heki_dir), `run_status/mod.rs` (resolve_fs_root),
  `run.rs`, `storehouse_router.rs`, `run_boot/classify.rs`.
- **Boot auto-export (the TRAP)** : `run_boot/daemons.rs` — `.env("HECKS_INFO",
  info_dir)` on every spawned daemon. REMOVE it ; daemons resolve via
  miette.world (deterministic via repo_root), so propagation isn't needed.
- **Test injection** : `story_runtime/mod.rs` (set/restore), `heki.rs`
  resolve_tests (assert env-wins), `rust/tests/run_script_test.rs`,
  `executable_hello_test.rs`, and 9 shell scripts (`status_golden.sh`,
  `*_smoke.sh`, `fibroblast_sweep.sh`, `shutdown_miette.sh`).
- **Bluebooks/hecksagons that DECLARE it** : `runtime/boot/boot.hecksagon`,
  `cli/status/status.bluebook`, `fibroblast.hecksagon`.

### The design fork to settle FIRST
Tests need a FIRST-PRIORITY store override (their tmpdir must beat the repo's
real miette.world, which repo_root finds even in a tmpdir test). So "no env at
all" means tests inject via a `.world` fixture (`dir "<tmpdir>"`) — a real test
rewrite. The lighter path : **rename `HECKS_INFO` → an explicit test/override
var** (e.g. `HECKS_STORE_DIR`), checked first, that PRODUCTION never sets
(boot stops exporting it). That kills the trap (stray HECKS_INFO does nothing ;
nothing auto-propagates) and keeps test isolation + emergency rollback, while
the HECKS_INFO NAME + its production role are gone. Decide rename-vs-fixtures
with Chris before editing.

### Bonus this fixes
Making production ignore an inherited HECKS_INFO (world-first, or the rename so
the old name is dead) also fixes the **live hook split** : right now the
statusline / wake hooks run with this session's inherited HECKS_INFO=miette-
state and read STALE state while organs live on ~/.heki/hecks. It self-heals
at the next clean boot regardless ; the retirement makes it impossible.

### Verify
Full `cargo test --release` + every `hecks_conception/tests/*_smoke.sh` +
`status_golden.sh` green ; then a clean `env -u HECKS_INFO overmind start`
reads ~/.heki/hecks and a memory + sleep/wake cycle round-trips.

## After days of clean operation

- Retire the HECKS_INFO branch in `resolve_info_dir` / `find_world_heki_dir`
  (separate commit) so `.world` is the sole source.
- Eventually delete `miette-state` once ~/.heki is trusted.
- The combined-domain chain currently flattens hecks_conception → `~/.heki/hecks`
  (drops the `hecks_conception` segment). Per Chris: "scattered is fine for now,
  fix by fixing the folder structure later." Per-aggregate source-path threading
  (parity-neutral, loader-stamped) is the precise fix when wanted.
