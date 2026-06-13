---
ref: restart-factories-phase1-finish-2026-06-12
status: done
category: session-restart
priority: high
posted_at: 2026-06-12
value: 'Phase 1 of first-class factories is BUILT and green in worktree factories-phase1-ir. Session died of an empty-tool-call repetition loop at ~630k context. Resume: investigate 1 failing specializer golden, commit (validator gate now passes), push branch, PR. ~30 min of mechanical finish.'
---

# Session-restart handoff — finish factories phase 1 (2026-06-12 evening)

Prior session built ALL of phase 1 and died of a generation pathology
(empty `storehouse__dispatch` calls in a self-amplifying loop — see the
conversation tail ; not a runtime bug, the door is healthy).

## Worktree
`/Users/christopheryoung/Projects/hecks/.claude/worktrees/factories-phase1-ir`
branch `worktree-factories-phase1-ir`, based on main @ 69e172cd (pushed).
Enter it with EnterWorktree path=... — do NOT create a new one.

## State — what is DONE and verified green
- Domain : bluebook.bluebook Factory entity (creates dropped), sentence.bluebook 3rd utterance kind
- Shape sources edited : ir_shape, dump_shape, parse_blocks_shape (parse_factory + extract_produces in snippet 03), parser_shape (factory/create → agg.factories), command_dispatch phase_03_prepare (is_factory_verb replaces cmd.creates)
- Generated + installed : ir.rs, dump.rs, parse_blocks.rs, parser.rs, command_dispatch.rs, validator.rs (all via worktree binary `rust/target/release/storehouse specialize <x>`)
- runtime/mod.rs : materialize_factory_commands boot seam (TRANSITIONAL — phase 2 deletes)
- specializer/dump.rs IMPORTS const gained Factory ; validator_checks.rs emit_non_empty now `commands.is_empty() && factories.is_empty()`
- Ruby mirror : Behavior::Factory (new file) ; behavior.rb autoload ; command.rb creates reverted ; aggregate_builder#factory upgraded from legacy hash to real node (produces kwarg, CommandBuilder body, Factory.from_command) ; create aliases factory ; entity-level create RETIRED ; workshop handle factory + create alias ; canonical_ir.rb factories key (before commands) + dump_factory + creates dropped
- Fixtures : parity/bluebooks/13_factory_keyword.bluebook (Sprint factory Plan ; Backlog factory DraftStory produces: Story ; Story command Start) — storehouse validate = VALID
- resolver_cascade_depth_test rewritten for Factory node ; validator tests factories: vec![] fixed ; dispatch_query.rs stale SystemTime import removed
- Gates last seen : cargo 70 binaries green 0 warnings (BEFORE the validator emitter change) ; parity 6/6 synthetic 24/24 ; pizzas smoke green

## What REMAINS (in order)
1. ONE failing test in `cargo test --release --test specializer_golden_test --test validator_rules_test --test validator_warnings_test` — 27 passed / 1 failed / 3 ignored, appeared right after the validator_checks.rs emitter edit + validator.rs regen. Almost certainly the validator byte-identity golden needs its expectation refreshed (or validator_rules_test asserts the old 'has no commands' behaviour for a factory-less aggregate — read the failure first).
2. Full `cargo test --release` green ; re-run the 6 parity suites with worktree binary on PATH.
3. Commit — staged file list is already in the worktree index (30 files). Commit msg draft at /tmp/commit_msg_factories_p1.txt. The bluebook validator gate now passes (13_factory fixture VALID). The ANTIBODY will block on rust/ruby files : per Chris (2026-06-12) FLOORS ARE EXEMPTED AT FILE LEVEL — add [antibody-exempt: …] doc-comment markers in the files the hook names (true kernel floors only), not in the commit message.
4. Push branch (pre-push runs cargo + 232 behaviors + integrity) ; open PR vs main with story summary + grammar example (factory "Plan" / produces: Story). No Co-Authored-By.
5. Update inbox/restarts_inbox/first-class-factories-2026-06-12.md : phase 1 done, phase 2 (two-path dispatch split, DELETE is_create heuristic + materialize seam) is next.

## Locked decisions (do not re-derive)
- Factory fields = Command minus creates plus produces (Option<String>, None = self)
- Entity-level create retired ; aggregate-only factories
- Phase-1 dispatch sliver = boot materialization + factories-vec is_create ; two-path split is phase 2
- `create` keyword parses to Factory transitionally ; retired in phase 4
