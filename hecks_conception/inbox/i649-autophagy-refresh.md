---
id: i649
title: Autophagy refresh — premise is stale ; the arc shipped, the tracker hasn't kept up
status: partial-findings
category: autophagy
created_at: 2026-05-20
created_by: agent (feat/autophagy-refresh)
---

# i649 — Autophagy refresh

## TL;DR

The task asked to refresh `lib/hecks/autophagy/`. **That directory does not exist
anywhere in the repo, by design.** The Ruby autophagy pipeline was deleted as
Phase E of the autophagy arc itself (Apr 2026). The self-image now IS the Rust
runtime under `rust/src/specializer/`, regenerated from shapes under `codegen/`.

There is, however, a real and concrete gap : the **autophagy tracker fixtures**
(`codegen/autophagy_tracker_shape/fixtures/autophagy_tracker_shape.fixtures`)
list **8 byte-identical Rust targets**. The actual `rust/src/specializer/`
directory contains **35 .rs files** plus two subdirectories. The tracker has
not been refreshed since Phase E shipped and is now significantly understating
both shipped coverage and the post-Phase-E surface area.

That mismatch is the legitimate "autophagy refresh" task. It's a one-file
fixtures update plus a tracker summary refresh — small, mechanical, and
high-value because it's the queryable data Miette consults to answer "how
much of me regenerates from a shape?"

## What the task assumed (and what's true)

| Assumption                                        | Reality                                                  |
|---------------------------------------------------|----------------------------------------------------------|
| `lib/hecks/autophagy/` exists and runs            | `lib/` does not exist ; deleted in Phase E (commit f717b324) |
| Autophagy is a Ruby pipeline that digests requires | The Rust specializer is the self-image ; no require-digestion anymore |
| `Hecks::Autophagy.digest!` is an entry point      | `Hecks::Autophagy` constant does not exist               |
| `project_autophagy.md` memory is current          | Memory predates Phase E ; describes the retired pipeline |
| Recent bluebooks (`voice`, `process_health`, `mcp digest`) might lack parsers | No `voice.bluebook` exists ; `process_health.bluebook` does ; the Rust parser handles both — the "lacks parsers" question is misframed |

Spot-check evidence :

- `git log autophagy/greeting-to-bluebook --oneline | grep "Phase E"` :
  - `fb650664 autophagy: Phase E PR 3 — docs sweep + tracker refresh`
  - `f717b324 autophagy: Phase E PR 2 — delete lib/hecks_specializer/ + Rust meta-specializers`
  - `3e3afbfe autophagy: Phase E PR 1 — delete bin/specialize + lib/hecks_specializer.rb`
- `find . -path './lib/*'` returns nothing.
- `find . -name 'autophagy*'` returns only `codegen/autophagy_tracker_shape/`
  and historical worktree paths — no live Ruby module.
- The tracker fixtures' `RetirementSummary` row for Phase E reads :
  > "100% autophagy completeness — everything that's still alive regenerates from a shape."
- `rust/src/specializer/mod.rs` exists ; `codegen/specializer/specializer.bluebook`
  exists. The specializer-as-shape, runtime-as-Rust handshake is live.

The premise of the task is therefore **terminal** at the level of
`lib/hecks/autophagy/`. There is nothing in that location to refresh because
nothing in that location was kept.

## The real refresh : the tracker is stale

### Coverage gap, concrete

`rust/src/specializer/` contains 35 .rs files (plus `conceiver/`, `run_boot/`,
`runtime/` subdirectories). The autophagy tracker fixtures list only 8 Rust
targets : validator, validator_warnings, fixtures_parser, behaviors_parser,
hecksagon_parser, dump, duplicate_policy_validator, lifecycle_validator.

The 27 .rs files NOT in the tracker include (sampled by inspection of
`ls rust/src/specializer/` against `codegen/` shape names) :

| Rust file                       | Probable owning shape (in codegen/)        |
|---------------------------------|--------------------------------------------|
| `adapter_llm.rs`                | (no shape yet — candidate)                 |
| `assemble.rs`                   | `assemble_shape`                           |
| `behaviors_fixtures.rs`         | `behaviors_fixtures_shape` (likely)        |
| `behaviors_parser_dispatch.rs`  | `behaviors_parser_shape` (sibling output)  |
| `behaviors_runner.rs`           | `behaviors_runner_shape`                   |
| `cf_function_proxy.rs`          | `cf_function_proxy_shape`                  |
| `cli_dispatch.rs`               | `cli_dispatch_shape`                       |
| `dispatch_query.rs`             | `dispatch_query_shape`                     |
| `embedded_bluebooks.rs`         | `embedded_bluebooks_shape`                 |
| `heki_query.rs`                 | `heki_query_shape`                         |
| `html_domain.rs`                | `html_domain_shape`                        |
| `ir.rs`                         | `ir_shape`                                 |
| `parse_blocks.rs`               | `parse_blocks_shape`                       |
| `parser_helpers.rs`             | `parser_helpers_shape`                     |
| `parser.rs`                     | `parser_shape`                             |
| `repository.rs`                 | `repository_shape`                         |
| `ruby_command_class.rs`         | `ruby_command_class_shape`                 |
| `run_statusline.rs`             | `run_statusline_shape`                     |
| `validator_checks*.rs` (×2)     | `validator_shape` (likely sub-modules)     |
| `validator_corpus.rs`           | `validator_corpus_shape`                   |
| `validator_morphology.rs`       | (no shape yet — candidate)                 |
| `wasm_worker.rs`                | `wasm_worker_shape`                        |
| `util.rs`                       | (no shape — utility code, likely hand-written) |
| `mod.rs`                        | (no shape — module declaration)            |

The `codegen/` directory contains **43 shape directories** (vs. 8 Rust targets
tracked). The tracker is roughly **20% complete** with respect to shipped Rust
+ shape pairings, not the "100%" the summary still claims.

### What the refresh should do

Not in this card — this card just documents the gap. But the work is :

1. For each .rs file in `rust/src/specializer/`, find its owning shape in
   `codegen/` (most are name-aligned : `assemble.rs` ↔ `assemble_shape/`).
2. Add a `RetirementTarget` row to the tracker fixtures with
   `ship_status: byte_identical` if `storehouse specialize <target>` reproduces
   it byte-for-byte, or `in_flight` / `not_started` otherwise.
3. Identify .rs files with NO shape (`adapter_llm.rs`, `validator_morphology.rs`,
   `util.rs`, `mod.rs`) and decide each : "needs a shape" (file new card) vs.
   "is hand-written infrastructure" (mark as out-of-scope in a new
   `kind: "infrastructure"` column or via convention).
4. Update `RetirementSummary.PhaseE` from the current narrative to reflect
   true file counts and LoC.
5. Re-validate the "100% autophagy completeness" claim. It may still be true
   (every .rs that should regenerate, does) but the tracker isn't showing the work.

That's a separate card and a separate branch.

## What this branch did

- Investigated the premise. Found `lib/hecks/autophagy/` does not exist.
- Read the `autophagy/greeting-to-bluebook` git history. Confirmed Phase E
  shipped on Apr 24, 2026.
- Counted Rust files vs. tracker entries — found the 27-file gap.
- Wrote this card.

**No code changes**, no test changes, no fixtures edits. The card is the
deliverable.

## Pointers

- Actual self-image source : `rust/src/specializer/` (35 .rs files + 3 subdirs)
- Shape catalog : `codegen/` (43 shape directories)
- Tracker shape (queryable data) : `codegen/autophagy_tracker_shape/`
  - `autophagy_tracker_shape.bluebook` — RetirementTarget + RetirementSummary
  - `fixtures/autophagy_tracker_shape.fixtures` — currently 8 Rust rows ; should be ~30+
- Memory to retire : `~/.claude/projects/-Users-christopheryoung-Projects-hecks/memory/project_autophagy.md`
  still says `Hecks::Autophagy.digest(lib_root:)` is the entry point. It isn't.
  That memory predates Phase E and should be rewritten to point at
  `rust/src/specializer/` + `codegen/`.
- Current session focus (per `inbox/restarts_inbox/latest.md`) is the
  `hecks_conception/ → ~/Projects/miette/` merge (#39), not autophagy. This card
  is for the queue, not the foreground.

## Next step (precise)

File a follow-up card "autophagy tracker refresh" that owns the mechanical
work of expanding `autophagy_tracker_shape.fixtures` from 8 Rust rows to the
full ~30 covering everything currently under `rust/src/specializer/`. That card
should also retire / rewrite the stale `project_autophagy.md` memory so future
agents don't get sent on this same wild goose chase.

Alternatively : if the principle is "the tracker IS the gap" (i.e. the tracker
gets re-derived from the shape/target correspondence automatically), then file
a card for the auto-derivation instead — discover targets by walking
`codegen/*/` and `rust/src/specializer/*.rs` and emitting fixtures rows from
the actual file system. That would close this drift class permanently.
