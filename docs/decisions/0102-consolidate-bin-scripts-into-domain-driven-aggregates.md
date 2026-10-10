# Consolidate 92 bin scripts into domain-driven aggregates and utility classes

**Status:** Proposed. Part of the larger Codebase and Custodian meta-domain effort.

## Context

Hecks has 92 files in `bin/`. Investigation found 81 are invoked from domain/lib/spec code (not standalone tools) — they're orchestration points embedded in the runtime but implemented as ad-hoc Ruby scripts instead of bluebook aggregates. This creates cognitive fragmentation: system behavior split between bluebook-declared aggregates (testable, journaled, composable) and hand-rolled scripts (subprocess calls, manual validation, no audit trail).

The remaining 11 bins are already project_cli launchers or thin wrappers with no consolidation needed.

## Decision

Bin consolidation follows a single principle: **Wrap a check/verify/measure script's *result* in a command dispatch instead of `puts` + `exit`.** The journal then gives you history (when did this drift, is it regressing) for free — no new persistence code required.

### 1. **New domain-driven aggregates** (with their own tooling-internal bluebooks)

Each aggregate models a system behavior that has pass/fail semantics worth remembering:

- **Release** — Tag, PublishGem, PublishNpm, Verify commands. Replaces `bin/release_gem`. Lifecycle mirrors `lib/hecks/release/runner.rb`'s state machine (pending → tagged → gem/npm published → verified). Invariants ("never publish before tag") expressed as `given` clauses. Adapters: Git, GemPublisher, NpmPublisher, CiPublisher (same pattern as `qa/adapters/github_checks.rb`).

- **RuntimeBaseline** — Refresh, Stale? commands. Replaces `bin/refresh_rspec_runtime_baseline`. Persisted artifacts already exist (`.log` files under `spec/`). New: explicit staleness invariant catches regressions (baselines silently regressed Sep 14→17 undetected).

- **LanguageContract** — Verify command. Replaces `bin/check_engine_agreement`. Journals pass/fail history instead of only current-state (declared comparators = runtime table = shared Comparison case = both engines route through `Comparison.holds?`).

- **DocCoverage** — Measure command. Replaces `bin/doc_coverage`. Journals undocumented/unexemplified counts over time instead of only the current gap list.

- **Codemod** — Propose, Verify, Apply commands. Replaces `bin/codemod_hoist_local_givens`, `bin/codemod_implicit_append_fields`. State machine already exists transiently in `Hecks::Codemod::Runner`; persisting it turns every automated edit into an audited event. Adapters: GitApply, IrVerifier.

- **Extend Deploy aggregate** — Add Lint (replaces `bin/lint_deploy_recipes`), Diff (replaces `bin/deploy_template_diff`) commands to the existing `lib/hecks/deploy/bluebook/deploy.bluebook`.

### 2. **QualityControl refinement** (extend existing aggregate)

Promote hand-coded business rules in `bin/qa_open_pr` and `bin/qa_pr_check` into domain:

- Move refusal logic ("branch-prefix check", "PR-cap-per-day arithmetic", "bug must be fixed with commit an ancestor of HEAD", "angle must be investigating") into `given` clauses on `Patch.Open`/`Improvement.Open`.
- Extract raw `git`/`gh` shelling (currently inline at lines 58-66, 144-168, 206-209 in `qa_open_pr` and lines 46-48, 105-124, 134-148 in `qa_pr_check`) into a new `GitPr` adapter, mirroring `qa/adapters/github_checks.rb`'s shape.
- Bind the currently-orphaned `IssueTracker` port declared in `qa/bluebook/quality_control.hecksagon`.
- `bin/qa_tick` stays a plain orchestrator (forks `qa_pr_check`, `qa_sweep --all`, `qa_generated_domains` as subprocesses) — this is legitimate process orchestration, not a concept needing its own aggregate.

### 3. **Utility class extraction** (stays without bluebook aggregate, but refactored)

Bins with no pass/fail state worth journaling extract to testable `lib/` classes per the `Release::Runner` pattern (dependency-injected OO, no subprocess calls, no ad-hoc validation):

- `bin/rspec_shard_files` — measure/mechanical tool, no domain boundary
- `bin/rspec_io_parallel_files` — measure/mechanical tool
- `bin/rust_kernel_coverage` — measure/mechanical tool
- `bin/standardize_comments_rust` — measure/mechanical tool, stays available as a pre-commit hook input
- `bin/check_era` — already a thin wrapper over existing Era/Lineage machinery
- `bin/model_check` — structural validator (rule violations still fail CI, not journaled as command results)

### 4. **Bin directory shape after refactor**

Each replaced bin becomes a thin ~15-line launcher (same shape as `lib/hecks/cli/run.rb` and existing `project_cli`):

```ruby
require "hecks"

args = ARGV
Hecks.boot do |container|
  command = Hecks.resolve(container, args.first.to_sym, **parsed_kwargs(args))
  result = container.resolve(:domain).commands.send(command.underscore, **command_attrs)
  puts result.to_json
end
```

No new generator needed; this mirrors the existing `project_cli` pattern by hand where a domain has custom arg parsing beyond a bare verb call.

## Consequences

- System behaviors that were invisible to the journal (a background bin exiting silently) become auditable events. Regressions are detectable because they appear in the event log.
- Behaviors previously scattered across 92 files now follow the domain pattern: testable, composable, drivable from specs.
- Invariant violations now fail **why** (a `given` clause with a human message), not **how** (a procedural check printing to stderr).
- QualityControl's hand-coded logic is now visible to the model — `bin/model_check` can verify PR-opening rules won't create unreachable states.
- Utility class extraction (Release::Runner pattern) makes measurement/mechanical code testable, mockable, and ready for pre-commit hooks or CI chains — no subprocess invocation, no hand-rolled error handling.

## Alternatives considered

- **Leave 81 bins as-is.** Status quo: cognitive fragmentation, no audit trail, hard to test. Rejected: the benefit of journaling system state is too high to ignore, and the refactor follows proven patterns already in the codebase.

- **Make all 92 bins into a single monolithic `SystemOperations` aggregate.** Simpler grouping, but loses the semantic distinction between Release (external coordination), RuntimeBaseline (CI health), DocCoverage (completeness), etc. Rejected: ADR 0053 and Release aggregate patterns show fine-grained aggregates win.

- **Keep utility classes as bin scripts; only promote the higher-value ones (Release, RuntimeBaseline).** Faster, lower risk. Leave rspec_shard_files, rust_kernel_coverage as-is. Drawback: utilities stay embedded in bin/, harder to test, pre-commit hook chains can't compose them. Rejected in favor of a complete refactor, but a phased approach is possible (Release first, then RuntimeBaseline, etc.).

## Open items

- Exact CLI shape for each new bin launcher (arg parsing strategy, where it lives — `bin/` vs. `lib/hecks/cli/commands/`).
- Whether new utility classes go into `lib/hecks/` or into a new `lib/hecks/tools/` directory to signal "no domain boundary."
- Which bins get the thin launcher treatment first (recommend Release, then QualityControl, then RuntimeBaseline for highest reuse).
- Rust parity: does `rust/host` need any of this, or do these stay Ruby-side operational tools?
- Integration with CI/CD: how are the new command launchers invoked in `.github/workflows/`, deploy automation, pre-commit hooks?
- Testing: do specs for each new bluebook need to live in `qa/specs/` or in a dedicated `spec/tools/` directory?

## Related decisions

- [ADR 0053](0053-transactional-outbox-for-domain-events-and-effects.md) — transactional outbox (enables journaling without new persistence code)
- [ADR 0054](0054-retire-rust-codegen-emit-projections-to-json-schema-instead.md) — retire rust/codegen
- Memory: `project_hecks_codebase_domain` — Codebase meta-domain (StyleEnforcer, RustCompiler, Transformer, Tester, Metrics)
- Memory: `project_hecks_custodian_bluebook` — Custodian meta-domain (system-level validators, introspection, migrations, release)
