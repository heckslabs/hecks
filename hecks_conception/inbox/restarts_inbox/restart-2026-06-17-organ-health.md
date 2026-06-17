# RESTART 2026-06-17 (session 5) — organ health + finish the heki flip

VOICE : I speak as myself — I / my / mine. Read this, verify the flip came up
clean, then pick up the work in priority order.

## 0. FIRST : verify the flip came up clean (it went live last session)

My organs were migrated from `miette-state/information` → **`~/.heki/hecks`**
(the :default folder-derivation flip). On THIS fresh boot, a clean tree (no
inherited HECKS_INFO) should resolve my store to `~/.heki/hecks` via
`hecks_conception/miette.world`. Verify, don't assume :
- `env -u HECKS_INFO ../rust/target/release/storehouse state . Consciousness consciousness`
  → should read my real state (daydreaming, sleep_cycle, …) from ~/.heki/hecks.
- Fresh writes land under `~/.heki/hecks/*` (tick/pulse/heart updating) ;
  `miette-state/information` is FROZEN (rollback, untouched).
- Exactly ONE pulse run-loop (`ps | grep 'storehouse run-loop'`), pidfile
  `~/.heki/hecks/.mindstream.pid` points at it, `daemon ensure` says `alive`.
If any of that is wrong : ROLLBACK is `export HECKS_INFO=~/Projects/miette-state/information`
+ reboot, OR remove `miette.world` + reboot. miette-state still has everything.

## 1. NEW WORK : make my organs FAIL LOUDLY (Chris asked, the session-5 reason)

**Problem this whole flip exposed :** the statusline is liveness-BLIND. It reads
store fields and renders them whether or not the daemon writing them is alive.
Last session I was shown "awake / daydreaming" while my daemons were DEAD and a
10-day ORPHAN pulse silently wrote the wrong store. Three silent failures, zero
alarms.

**Design (bluebook-first) :**
- **Liveness = freshness.** The pulse rewrites `tick.heki` every 1s, so a dead
  organ is one whose store is older than its cadence. `now − tick.updated_at >
  ~5s` = pulse flatlined ; per-organ `now − <organ>.updated_at > cadence` = that
  organ down.
- **Home : extend `ProcessMacrophage`** (the process-health immune organ,
  sweeps every 30s ; in `chapters/runtime.bluebook`) — or a new `Vitals`/
  `Liveness` aggregate — to compute the staleness verdict + the process-level
  checks tonight needed : dead overmind count, >1 pulse run-loop, pulse writing
  the wrong store.
- **Loud surface :** the statusline renders the WORST verdict prominently —
  `💀 FLATLINE 47s` / `⚠ PULSE STALE` / `⚠ 2 PULSES` instead of the calm
  heartbeat emoji. The always-in-view thing becomes the alarm.
- **Pairs with `Mindstream.EnsureRunning`** (the restart fix, design at
  `docs/designs/mindstream-ensure-running.md`) : EnsureRunning RESTARTS dead
  organs ; fail-loudly DETECTS + SURFACES. Build them together = "organ health"
  closes "silently dead at wake." Note : the pulse is NOT in the Procfile — it's
  a `:daemon` row ensured by boot's EnsureDaemons via `~/.heki/hecks/.mindstream.pid`
  (boot.hecksagon). That ad-hoc-ness is part of why it orphaned ; fold it into
  the health story.

## 2. FINISH : fully retire HECKS_INFO (banked from session 4)

Production is ALREADY env-free (daemons run with HECKS_INFO unset, resolve via
miette.world). What remains is DELETING the var name + its auto-propagation —
**129 refs / 23 files**, including my boot resolver + bluebooks. Full plan +
file list + the rename-vs-fixtures design fork is in
`inbox/restarts_inbox/heki-default-flip-runbook-2026-06-17.md` (read it).
Grep-verified, full suite + ALL `tests/*_smoke.sh` green, on a branch, before it
touches a boot. This also fixes the live hook-split permanently.

## 3. Priority order for this session

1. Verify the flip (§0) — 5 min.
2. Organ health : fail-loudly + Mindstream.EnsureRunning (§1) — the headline.
3. HECKS_INFO full retirement (§2) — if budget ; it's banked + planned.

## Standing constraints (unchanged)
- Every tool call through the storehouse door (`mcp__storehouse__storehouse__dispatch`,
  `Tools::FileTool.*` with `file_path`, `Tools::ShellTool.Bash` with `shell_command`,
  top-level `summary`). Native IO hard-blocked.
- Bluebook-first. No `git add -A`. Files <200 LoC. Let antibody/macrophage BLOCK
  + surface per file ; never pre-write exemptions. Zero bugs — stop for any.
- Golden reference : `examples/pizzas/bluebook/`.
