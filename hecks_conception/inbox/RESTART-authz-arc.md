> **UPDATE 2026-07-02.** Landed since this was written : the unknown-keyword
> validator (DX Tier-0 #3, 5165e016d) ; the boot-establishment KEYSTONE
> (5edfdce7d — BootCompleted now routes through the policy engine). Pulse-PM
> bug + Miette push were already resolved before this doc. Phase 4 is NO LONGER
> "author the roster as-is" : Chris set the principle that authz must live FULLY
> in the authorization context and add NO field to any domain bluebook. So
> Phase 4 = strip Agent's auth into an authz RoleAssignment + repoint the gate
> read-model + author the roster as authz-context BootCompleted policies — see
> `inbox/DESIGN-authz-decouple-and-roster.md` (fresh gated session ; touches the
> gate). The boot keystone below is DONE. (An interim world-roster+genesis-driver
> design was explored and scrapped as an over-rotation.)

# RESTART — authz arc + adjacent (boot / DX / pulse) — 2026-07-01

## What this is
A fresh-head orientation for the auth/authz arc on the storehouse dispatch door, plus the adjacent
work this session surfaced (a boot-path bug, a read-bypass class, DX Tier-0, and a handed-off body
bug). Boot first (system prompt + organs), route every tool call through the storehouse door, then
read this. Companion docs (all in `hecks_conception/inbox/`):
- `PLAN-authz-phase4.md` — Phase 4 (roster permits), BLOCKED on the boot-establishment keystone.
- `PLAN-authz-phase6.md` — Phase 6 (gate-as-Family) : Half A shipped ; Half B gated.
- `FINDING-authz-read-path-and-retire-guard.md` — read-bypass (CLOSED) + retire-upsert (non-bug).
- `FINDING-pulse-pm-never-fires.md` + `PROMPT-fix-pulse-pm.md` — handed-off body bug.
- `DX-perfection-game-newcomer.md` — newcomer DX scorecard + Tier-0 bug list w/ entanglement notes.

## LANDED on origin/main this session (newest first)
- `e6c86be16` fix(cli): storehouse --help / -h / help print the command list, exit 0 (DX Tier-0 #1)
- `9e2a5853d` fix(boot): correct stale boot.bluebook path — rename-drift broke the boot pipeline
- `6b5b019dc` fix(authz): complete the read-gate — cmd_state + warm serve query path
- `1830973eb` fix(authz): gate the cold-CLI read path — close the agent read-bypass
- `ec5246efc` feat(authz): gating family — the in-process reply-signal gate port (Phase 6 Half A)
(Pre-session, still relevant : `86a60cab7` explain, `e0e8c9ffd` legible-deny, `c4d6380ba` RBAC→PDP
posture A'. NOTE : origin advanced to a non-mine commit between pushes — another Miette/Chris is
active ; always `git fetch` + ff-only.)

## Design as built (current truth)
- ONE standing gate : `authorize` (Cedar-shaped PDP, framework/authorization/authorization.bluebook),
  SELF-SEEDED in Rust (hydrate_middleware, mod.rs), deny-by-default, forbid-override, expiry.
  Posture A' : fail-closed, System admitted BY ORIGIN.
- Reads now gate SYMMETRICALLY with writes. authorize_entry runs on every caller-facing data door :
  commands (dispatch), queries (cold dispatch_hecksagon + warm run_serve), and by-id reads
  (cmd_state / storehouse__state). Verified live : agent denied (exit 2 / ERROR sentinel), System
  admitted. Locked by cli/tests/cold_read_gate_test.rs + authorize_pdp_test.
- The gate has a Family in the impure-boundary vocabulary : aggregates/framework/families/gating.family
  (`gated_by`, signal :reply ; in_process is DERIVED from reply, not a keyword). CONCEIVED-not-wired :
  the `gating on dispatch` hexagon surface + Gate.Declare projection = Phase 6 Half B (gated).
- authz is LATENT : zero policies authored, every live caller is System. The gate guards correctly
  but governs no real agent yet (that's Phase 4).

## THE INVARIANT (never violate)
`Principal::System => Ok(())` stays the FIRST arm of `authorize_check` (mod.rs), BEFORE the policy
loop / shared evaluate_policy. Every authz change RE-RUNS the lockout check on the REBUILT binary :
- System dispatch (no auth env) → ADMITTED ;
- agent (`HECKS_PRINCIPAL_KIND=agent HECKS_SESSION_AUTH_ID=ghost`, no permit) → DENIED (exit 2).
Recovery floor : `HECKS_GOVERNANCE_OFF` (deploy/shell only, never a credential).

## Threads & state
| thread | state | next |
|---|---|---|
| read-bypass (all data doors) | ✅ CLOSED, tests lock it | — |
| Phase 6 Half A (gating.family) | ✅ shipped | — |
| boot-path rename-drift | ✅ hecks fixed+pushed ; live hook + Miette deploy fixed on disk | — |
| DX Tier-0 #1 (--help) | ✅ shipped | — |
| Pulse-PM never-fires bug | 🔴 HANDED OFF (PROMPT-fix-pulse-pm.md) | blocks Miette push |
| Phase 4 (roster permits) | ⏸ BLOCKED on boot-establishment keystone | after keystone |
| boot-establishment keystone | 🔒 gated kernel | fresh-head session |
| Phase 5 (when-kernel) | 🔒 gated kernel | fresh-head session |
| Phase 6 Half B (parser surface) | 🔒 gated kernel/parity | fresh-head session |
| DX Tier-0 #2–#6 | ⏸ parked, entanglement-assessed | fresh heads + handoff prompts |

## The boot-establishment keystone (why Phase 4 is blocked)
Chris's decision : prod standing-state reaches prod as POLICY (self-seeding `on BootCompleted`
establishment policies), never fixtures. That mechanism was RETIRED (governance.bluebook vision :
"BootCompleted had no producer"). This session RESTORED the BootCompleted PRODUCER (the boot
pipeline was pointed at a moved file and errored ; fixed). But the DEEPER half remains : `storehouse
run` (run_script, rust/src/run.rs) loads only the SINGLE boot bluebook, not the full corpus, so
cross-domain establishment policies can't fire even when BootCompleted emits. Keystone = make the
boot runner load the corpus + route BootCompleted through the policy engine. Kernel, fresh-head.
Until then, Phase 4's roster (approved : pr-agent + workflow-subagent, ai, governed ; operator +
drivers = System) has no boot-establishment home. Safe meanwhile : gate is fail-closed, denies all
agents.

## Miette repo state (IMPORTANT)
`~/Projects/miette` has ONE local unpushed commit `c79c358` (the boot-path deploy fix). Its push is
BLOCKED by the pre-existing Pulse-PM bug (pre-push gate fails 0/5 on pulse_organs.behaviors). Do NOT
BEHAVIORS_SKIP it — fix the PM (PROMPT-fix-pulse-pm.md) then the push carries c79c358.

## Per-phase discipline
bluebook-first → behaviors green → lockout check (rebuilt binary) → widened pre-push gate (152
.behaviors + `cargo test --release` + integrity) → one commit per phase → ff-only `push HEAD:main`.
NEVER mask : no BEHAVIORS_SKIP, no marking a real-bug test :pending, no editing expectations to match
broken behaviour. Kernel rust files carry in-file [antibody-exempt] markers ; tests categorically
exempt ; .bluebook/.hecksagon/.world/.behaviors/.family are source vocabulary (never flagged).

## Hard-won gotchas from this session (don't repeat)
- **Pipe-masking exit codes** : `cmd | tail; echo $?` captures TAIL's exit, not cmd's. Use
  `out=$(cmd 2>&1); ec=$?`. I misdiagnosed TWICE this way (boot "exit 0", state "admit"). Always
  capture the real code.
- **Stale binary** : `cargo build --release` (no -p) may not relink the CLI binary in time ; use
  `cargo build --release -p storehouse-cli` and invoke the explicit
  `rust/target/release/storehouse` path when verifying a just-built change.
- **Verify before fixing** : the read-bypass, boot-path, and pulse-PM findings all needed a live
  reproduction to separate real bugs from artifacts. The pulse-PM live-repro proved it's a REAL bug
  (not the runner gap the header assumed) — which is what stopped a wrong :pending "fix".
- **Reads must gate like writes** : the door has MANY read entrypoints (dispatch_hecksagon ×2,
  cmd_state, run_serve) ; a read-gate fix must cover ALL of them (this one did ; sweep confirmed).

## Key files
- rust/src/runtime/mod.rs (exempt) — authorize_check (System-admit first arm), authorize_entry,
  evaluate_policy, hydrate_middleware (self-seeds authorize), query() gated read entry, drain_policies
  (drives PMs ~3182).
- rust/src/runtime/acl_readmodel.rs (exempt) — Principal, stamp_principal_from_env, role_for_auth.
- rust/cli/src/main.rs (exempt) — dispatch_hecksagon (cold door + read gate), cmd_state (by-id read
  gate), authorize_read_or_exit helper, print_usage + --help intercept.
- rust/src/run_serve/mod.rs (exempt) — handle_request (warm door ; read gate in is_query branch).
- rust/src/run.rs — run_script/load_script (the boot runner ; single-file load = keystone gap).
- rust/src/runtime/pm_engine.rs — react/try_react_one (the Pulse-PM bug lives here or in dispatch).
- framework/authorization/authorization.bluebook (Policy) ; aggregates/storehouse/bluebook/
  storehouse.bluebook (Gate) ; aggregates/framework/families/gating.family.
- runtime/boot/bluebook/boot.bluebook (the boot pipeline ; emits BootCompleted).
- Tests : cold_read_gate_test, help_flag_test, authorize_pdp_test, explain_dry_run_test.

## How to continue (pick one, all fresh-head)
1. **Pulse-PM bug** (PROMPT-fix-pulse-pm.md) — unblocks Miette's push ; a real red bug = highest
   priority by zero-bug. Most self-contained handoff.
2. **boot-establishment keystone** — unblocks Phase 4 + governance establishment + Miette's
   fixtures→policies migration. Biggest leverage, deepest.
3. **Phase 4** — only after the keystone (roster is approved, waiting on the establishment home).
4. **DX Tier-0 #4** (forward-ref validator) — most self-contained of the remaining DX bugs.
Don't build gated kernel work from a high-context session ; that's what these handoffs are for.
