# Handoff: governance barrier + "policies, not fixtures"

## State of main (pushed, origin/main = bf380359d)

Three commits shipped this session, all green through the full pre-push gate
(cargo test --release, referential-integrity, 144 .behaviors):

- `a7ebc7c9a fix(heki)` — `folder_address` now strips git-worktree path
  segments (`.claude/worktrees/<name>/`). Before this, ANY aggregate loaded
  from a worktree stamped a polluted `realm_path`, so realm-qualified dispatch
  (`Hecks::World::...`) silently failed from inside a worktree. Worktrees are
  now safe for realm-qualified resolution.
- `426a3fec9 feat(governance)` — Layer-1 barrier rehome: `GovernedDoor` moved
  from `discipline/immune_system/macrophage/` into `framework/governance/`
  (it's the synchronous pre-act skin, upstream of the async immune cells).
  `RecordBlock` folded into `Governance::Violation.Record`; added
  `Violation.ListAll`/`ByTool` + `Policy.ByName`. Both hooks
  (`bin/governed-door-hook` PreToolUse, `bin/governed-door-complain`
  PostToolUse) repointed to `Governance::*`. Live store seeded + verified.
- `bf380359d feat(governance)` — "policies, not fixtures" (this session's arc,
  below).

## The architecture decision (Chris)

**Prod standing-state must reach prod as POLICY — declared, self-seeding at
boot — never as test fixtures.** Fixtures stay TEST-ONLY (the behaviors runner
auto-seeds query read-models from them; deleting them breaks query tests).
The mechanism is the EXISTING reactive `policy` block (`on Event` / `trigger
Cmd` / `with "k","v"`) — no new concept. A genesis event fires at boot;
establishment policies react and upsert the standing state.

This is conceived for governance as the WORKED EXAMPLE. The corpus-wide goal
(Chris chose "design corpus-wide"): migrate the ~23 other fixtures-as-prod-seed
(`aggregates/fixtures/` = Miette's brain: vows, organs, being, memory,
awareness, sleep, tongue, vocabulary, first_breath… + agent_instrumentation,
plan) off `.fixtures` onto establishment policies. NOT done yet — do it after
the mechanism below is solid (idempotent + verified-at-real-boot).

## What's built (in bf380359d)

- `aggregates/framework/governance/governance.bluebook` — 13 establishment
  policies: the deny-by-default `Policy` as an ordered event-chain
  (`on BootCompleted -> Propose`; `on Policy.Proposed -> Permit`;
  `on Policy.Permitted -> Activate` — events qualified so a sibling domain's
  bare `Proposed` can't trigger it) + 10 governed-door `Register` policies
  firing in parallel `on BootCompleted`.
- `runtime/boot/boot.bluebook` — built the `BootCompleted` event that
  `BeginBoot`'s doc-comment always promised. New `CompleteBoot` command emits
  it after `SurfaceWakeReport` (the functional end of boot), DECOUPLED from
  studio: `StartStudio` now fires `on BootCompleted` as a post-completion
  effect, no longer a gate. Lifecycle: `surfacing -> completing
  (CompleteBoot) -> studio_starting (StartStudio) -> done`.
- Idempotency, partial: `Activate` accepts `active` as a from-state
  (re-activate = no-op); doors `Register` upsert by `tool` identity. Both
  safe to re-fire on reboot.

## Open follow-ups (kernel-floor — fresh-head, gated; in priority order)

1. **append-unique MutationOp** (blocks allow-list idempotency). `Permit`
   uses `append`, so the `permitted` list re-appends every reboot. There is
   NO append-unique/upsert MutationOp (enum: Append/Set/Increment/Decrement/
   Clamp/Decay/Delete/Multiply/Remove/Toggle). `apply_mutations` is a
   SPECIALIZER target (`rust_specializer_produces_byte_identical_interpreter_rs`)
   — so adding the op = codegen fragment edit + golden regen. Add e.g.
   `AppendUnique` keyed by a declared field, then change `Permit`'s
   `then_set :permitted, append:` -> the new op. (I tried `upsert:` — it is
   NOT a real op; the parser silently took it as the literal string
   "upsert:" and broke the field. Reverted.)
2. **Verify boot-runner -> policy-engine.** Unverified whether the Rust boot
   runner (`storehouse run runtime/boot/boot.bluebook`, mirrors run_status,
   walks its own chained policies) emits `BootCompleted` THROUGH the general
   policy engine so governance's establishment policies actually fire at a
   REAL boot. The reactive-policy mechanism IS proven via plain CLI dispatch
   (a sentinel policy fired cross-domain). The boot-runner path is the gap.
   Can't test without running the real boot (heavy side-effects; no behaviors
   safety net). May need wiring the runner to publish through the bus.
3. **Parser silently accepts unknown MutationOps** — took `upsert:` as a
   literal instead of erroring at validate. Close this validation gap.

## Gotchas / hard-won facts

- Worktree builds: `cargo build --release -p storehouse-cli` (the bin is in
  package `storehouse-cli`; plain `cargo build --release` builds only the lib,
  and `--bin storehouse` is rejected — "no bin target in default-run").
- Worktree pre-commit: the specializer golden test needs the worktree's
  `target/release/storehouse` BUILT (it shells to it); behaviors corpus from a
  worktree was failing ONLY because of the folder_address bug — now fixed.
- loc-ratchet baselines on `origin/main`; if main is behind, it counts the
  delta of unpushed commits. Push main first or it false-blocks.
- Behaviors QUERY tests need `.fixtures` (read-model seeding); command tests
  use setups. So fixtures can't be deleted even though prod doesn't use them.
- Bulk same-string edits in a bluebook: `sed -i ''` is fine (it's not Ruby
  code); FileTool.Edit needs unique old_string.

## Pollution to clean (live heki store; harmless, no delete verb exists)

- `Governance::Policy` named `idem-test` (from an idempotency probe).
- `Governance::GovernedDoor` row `FirstBreathProbe` (from a mechanism probe).
Neither `Policy` nor `GovernedDoor` has a delete command; cleaning needs a
Forbid-equivalent or heki surgery. No tool ever matches `FirstBreathProbe`,
so the live hook never trips on it.

## Key files

- `aggregates/framework/governance/governance.bluebook` (Policy, GovernedDoor,
  Violation, EnforcementAdapter + 13 establishment policies)
- `aggregates/framework/governance/governance.behaviors` (11 tests),
  `governance.fixtures` (test-only), `governance.hecksagon` (adapter :heki)
- `runtime/boot/boot.bluebook` (BootRun + CompleteBoot/BootCompleted)
- `bin/governed-door-hook`, `bin/governed-door-complain` (live hooks)
- `rust/src/heki.rs` `folder_address_segments` (worktree fix + unit test)
- `rust/src/runtime/command_dispatch.rs` `resolve_fully_qualified`,
  `rust/src/corpus_loader/mod.rs` `load_combined_domain` (merge/realm stamping)
