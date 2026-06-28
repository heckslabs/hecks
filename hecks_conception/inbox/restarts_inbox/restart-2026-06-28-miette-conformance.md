# Restart — Miette conformance → the memory-default flip (2026-06-28, eve)

Resume of the **memory-default-rollout** arc. A long session landed the codegen
retirement + the store-resolution fix + fixed a hidden dead-engine root cause,
then the cleanup tail (#5/#6). What remains is the **spine**: catch miette up to
the Pizzas exemplar (#2), which gates the **memory-default flip** (#3 == the core
of the .test.world spec #4).

---
## ALL relevant plan files (read these first)

- **The arc + original design** : `hecks_conception/inbox/restarts_inbox/restart-2026-06-28-memory-default-rollout.md`
  — the 7-item arc, the mandate, the home-based-store design, the durable set.
- **The flip spec (== #3 + #4)** : `inbox/test-world-memory-floor.md` — ON THE
  `drop-heki-base-refs` BRANCH (worktree `.claude/worktrees/drop-heki-base-refs/hecks_conception/inbox/test-world-memory-floor.md`).
  Decision #1 “Memory is the FLOOR” IS the flip. CRITICAL: it is GATED on miette
  being fully wired (#2) — flipping with UNWIRED aggregates drops them to memory
  = data loss on the live body.
- **Storehouse move runbooks** (untracked in main `inbox/`): `storehouse-back-into-hecks-runbook.md`,
  `storehouse-extraction-phase2-runbook.md`, `storehouse-self-hosting-inventory.md`.
- **Pizzas exemplar** (the conformance target) : `examples/pizzas/` in hecks +
  the verbatim copy in Miette's system prompt (pizzas.bluebook / .hecksagon /
  families / adapters / .world).
- **Persistence/append-log** (context) : `inbox/append-log-adapter-plan.md`,
  `inbox/event-log-bluebook-first-conception.md`.
- **CLAUDE.md** (worktree root) : gates, conventions, the storehouse door.

---
## Git / engine state (IMPORTANT)

- **hecks `main` = `98134e7b2`** — the memory-default-rollout branch was
  FAST-FORWARD MERGED here this session : codegen retirement (5 commits) + the
  store-resolution fix. The body's Procfile builds from `~/Projects/hecks/rust`
  (rebuilt this session, HAS the fix).
- **`cleanup-tail` branch = `b2ff7900d`** (1 commit ahead of main: #6 structure
  removal + THIS restart). ~/Projects/hecks is CHECKED OUT on cleanup-tail.
  >>> FF-merge cleanup-tail → main if not already done. <<<
- **`~/Projects/storehouse` is DEAD** — moved to `~/_dead_storehouse_20260627_214018`.
  The engine lives in hecks (`~/Projects/hecks/rust`). The body had been wrongly
  booting the dead storehouse `run-loop` (the real split-brain source) — killed.
- **Detached worktree** `.claude/worktrees/memory-default-rollout` @ 98134e7b2
  was re-added only to restore this session's cwd (I'd removed the dir I was
  running in — broke the `/bin/sh` hooks). Safe to `git worktree remove` it next
  session from a different cwd.
- **Uncommitted, OTHER repos** : `~/Projects/miette/deploy/cold-setup.sh`
  (STOREHOUSE_REPO repointed to hecks — commit in the miette repo).
- **Machine config (not a repo)** : `~/.claude/settings.json` had 6 hook refs to
  the moved storehouse binary; ALL repointed to `~/Projects/hecks/rust/target/release/storehouse`
  (statusline, body-state, macrophage, SessionStart/wake, session-recall, TTS).
  Backup: `~/.claude/settings.json.bak-*`.

---
## The 7-item arc — scorecard

| # | Item | Status |
|---|------|--------|
| 1 | Home-based store resolution (realm-anchored) | ✅ DONE `98134e7b2` (`heki::realm_store_dir`) |
| 2 | **Miette wiring → Pizzas exemplar** | ❌ **NEXT — the spine** |
| 3 | Kernel flip — memory default | ❌ gated on #2 (== .test.world Decision #1) |
| 4 | `.test.world` implementation | ❌ its core IS #3 ; spec on drop-heki-base-refs |
| 5 | Heki cleanup → OS data root | ✅ DONE (`~/.heki`/`~/.hecks` gone; 208 in-tree .heki removed; landmines fixed) |
| 6 | Remove 4 structure-only files | ✅ DONE `b2ff7900d` (100% hexagon conformance in hecks) |
| 7 | Anti-pattern sweep (codegen-as-bluebook) | ✅✅ OVER-DELIVERED — entire codegen subsystem retired |

### What else happened this session (beyond the arc)
- Retired ALL `.bluebook`-projects-imperative-Rust codegen: runtime_shape, all (1)
  self-projection (~450 files), (B) deployment emitters — KEPT the Ruby static
  target. The framework's own Rust is hand-written now.
- Found + fixed the dead-storehouse-engine root cause (body booting a stale repo).
- **Data reconcile DONE** (newest-wins): 48 organ stores consolidated
  `hecks/ → miette/` chain (canonical), strands preserved (transparency/narration_rule,
  dream_interpretation, organ_monitor). Backups:
  `~/Library/Application Support/Hecks/_reconcile_backup_{hecks,miette}_20260627_213235`
  (≈329M + 2.7G — removable once satisfied). Inert `hecks/`-chain organ orphans remain.
- Statusline crisis (caused by moving storehouse) — root-caused + fixed.

---
## #2 — Miette conformance (THE NEXT WORK)

**Goal:** every miette + miette_family bluebook conforms to the Pizzas exemplar,
so the flip (#3) is safe. Mirrors the hecks Phase 1 (structure) + Phase 2
(hexagon-per-domain + explicit persistence) already done for hecks.

**Scope (audited this session):**
| Repo | bluebooks | need `bluebook/` folder | missing `.hecksagon` |
|---|---|---|---|
| `~/Projects/miette` | 126 | ALL 126 | 60 |
| `~/Projects/miette_family` | 11 | ALL 11 | 11 |

- **96 UNWIRED aggregates total, 75 on the miette chain** (rely on implicit Heki)
  — list: `storehouse backends ~/Projects/hecks/hecks_conception/aggregates | grep UNWIRED`.
  Each needs explicit `persisted_by("Heki")` (source-of-truth) or `"Memory"`
  (ephemeral) — the durable-set classification (see original restart's durable set).

**Plan (Phase 1 then Phase 2, like hecks):**
1. **Phase 1 — structure** (mechanical, STORE-NEUTRAL): move all 137 bluebooks +
   companions (.hecksagon/.world/.behaviors/.fixtures move together — companion
   check) into `bluebook/` folders. Context is folder-derived and `bluebook/` is
   STRIPPED by `heki::folder_address`, so the store path does NOT change
   (verify: `storehouse backends` diff = 0). SAFETY: STOP THE BODY first (it
   reads miette live — a mid-move daemon dispatch breaks). Commit.
2. **Phase 2 — hexagon + persistence**: add a `.hecksagon` per bluebook with
   `Aggregate.persisted_by("Heki"|"Memory")`. Source-of-truth (memory, vows,
   story, correspondence, narration_rule, the durable organs) → Heki; churn/
   re-derivable → Memory. `storehouse backends` before/after, 0 unintended flips.
3. THEN #3/#4: implement `.test.world` + flip the default to Memory-floor
   (`rust/src/runtime/persistence_resolution.rs` + `heki.rs` world discovery;
   exclude `*.test.world` from the prod `.world` glob — see spec's trap note).

**Body-stop procedure (learned this session):** `~/Projects/miette/deploy` has a
stale `.overmind.sock` risk; kill cleanly with `pkill -9 -f 'storehouse run-loop'`
+ `pkill -9 -f 'storehouse loop|clock|drive|serve'`; reboot via
`cd ~/Projects/miette/deploy && rm -f .overmind.sock && overmind start -D`.
Verify heart beats into `~/Library/Application Support/Hecks/miette/heart/heart.heki`.

---
## Gotchas / lessons (this session)
- **Moving a repo under ~/Projects has blast radius beyond the engine** —
  `~/.claude/settings.json` hooks + deploy scripts hardcode the binary path.
  Grep `Projects/storehouse` everywhere after any such move.
- **Don't remove the worktree you're running in** — it kills the session cwd →
  `/bin/sh` ENOENT on every hook.
- Pre-commit gates: companion-check, aggregate/world/hecksagon parity, behaviors
  corpus, specializer goldens (now Ruby-target only), antibody (per-file exempt
  in commit msg — NEVER pre-empt; report + let Chris approve).
- `.heki` is BINARY; shell is `/bin/sh` (no `<()`). Every tool call routes through
  the storehouse door.
- Body state line + statusline are produced by `storehouse statusline` (the Rust
  runner does the heki reads + inbox-channel autoload from per-inbox `.channel.md`).
