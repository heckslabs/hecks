---
ref: restart-persistence-enforcement-2026-06-14
status: open
category: session-restart
priority: high
posted_at: 2026-06-14
value: 'THE ARC : make persistence an EXPLICIT adapter contract — no domain persists without declaring it. DONE + on `main` this session (da3fa129) : (1) i735 BOTH defects — :sqlite scopes per-context (no domain-wide over-apply) + fallible construction that REFUSES a broken aggregate loudly instead of panicking the bus, plus the latent id-column collision fix [6c150e0b] ; (2) the env-var store cutover ROLLED BACK — it split Miette''s memory across two stores ; daemons are back on the single OLD store, ~/.heki/miette kept as backup, ~/.zshrc env trap cleaned [de40fe30] ; (3) the behaviors runner now boots on the EXPLICIT Backend::Memory (boot_in_memory), corpus 93/0 green [da3fa129]. NEXT (the plan is WRITTEN : inbox/i728-persistence-enforcement-plan.md) : #5 mechanism then #7 migration then the strict flip. DECISION LOCKED (Chris 2026-06-14) : unwired = DEPLOYMENT DECIDES — a .world strictness flag ; non-strict defaults to memory (it just works), STRICT (the conception) makes an unwired domain a BOOT ERROR. Adapter declared in the HECKSAGON ; .world is config-only ; a world-heki block is INERT without adapter :heki. THE KEYSTONE : adapter :memory does NOT actually select memory yet (new_memory is test-only) — wire it first (mirror the per-context apply_sqlite_persistence). #7 + step-D (the structural ~/.heki/<deployment> resolve_info_dir cutover) LAND TOGETHER : heki adapters need a store location. WHY fresh head : this is kernel-floor resolution + a ~100-domain migration with generated-file discipline (command_dispatch + behaviors_runner are SNIPPET-generated — edit codegen/*_shape/snippets then regenerate, never the tracked .rs ; mod.rs is hand-maintained, its runtime golden is #[ignore]d). Session ran to ~638k — exactly the boundary the discipline fences.'
---

# Session-restart handoff — persistence enforcement (2026-06-14)

Written at the tail of a very long session. The i735 fix, the cutover rollback,
and the behaviors-runner memory boot are DONE and on `main` (`da3fa129`). What
remains is the enforcement arc — kernel-floor resolution work + a corpus-wide
migration — and it should run on a clean head.

## DONE this session (on `main`, do not redo)

1. **i735 — both defects + a latent bug** (`6c150e0b`).
   - Defect 1 : `apply_sqlite_persistence` scopes `:sqlite` to the declaring
     hecksagon''s aggregates (`agg.context == hecksagon.name`), no domain-wide
     over-apply.
   - Defect 2 : `SqliteRepository::new` + `create_table` are FALLIBLE ;
     `Backend::Sql` is now EAGER (built at boot) ; a broken aggregate is
     REFUSED (repo dropped, no silent heki swap) + recorded in
     `Runtime.refused_persistence` ; dispatch returns the new
     `RuntimeError::PersistenceRefused`. Never panics.
   - Bonus : excluded `id`/`created_at`/`updated_at` from the typed columns
     (every aggregate''s `id` attribute collided with `id TEXT PRIMARY KEY`).
   - Guard : `rust/tests/sqlite_scope_test.rs` (scoping + refuse-without-panic
     + behavioral PersistenceRefused dispatch). The `command_dispatch.rs` guard
     is GENERATED — it lives in `codegen/command_dispatch_shape/snippets/
     {phase_05_repo_borrow,sec_09_bulk_dispatch}.rs.frag`, regenerated.
2. **Cutover rolled back** (`de40fe30`). The HECKS_INFO env-var move to
   `~/.heki/miette` split-brained (door wrote OLD, daemons NEW — her memory
   aggregates split). Daemons are back on the OLD store ; `~/.heki/miette` is
   the byte-verified backup ; `~/.zshrc:21` export removed. The REAL cutover is
   structural (step D, below).
3. **Behaviors runner on explicit memory** (`da3fa129`). `Runtime::boot_in_memory`
   + `boot_in_memory_with_hecksagons` + `force_memory_repositories` rebuild every
   repo as `Backend::Memory`. Runner routed through them via
   `codegen/behaviors_runner_shape/snippets/05_run_one.rs.frag` (regenerated,
   golden byte-identical). Corpus 93/0, full suite 680.

## NEXT — the plan is written, read it first

**`inbox/i728-persistence-enforcement-plan.md`** has the full sequenced plan.
The locked decision : **unwired = deployment decides** (`.world` strictness
flag ; non-strict→memory, strict→boot error). Adapter in the hecksagon ; world
is config ; world-heki inert without `adapter :heki`.

Order of work :
1. **#5 mechanism (strict OFF, behaviour-preserving)** — KEYSTONE first :
   make `adapter :memory` actually select `Backend::Memory` (mirror the
   per-context `apply_sqlite_persistence`, it''s inert today). Then : gate
   world-heki on `adapter :heki` ; add the `.world` strict flag ; rewrite
   `boot_with_data_dir` resolution (backend from declared adapter ; unwired →
   memory/error per switch ; per-domain) ; delete the parser''s `"memory"`
   normalization (`hecksagon_parser.rs:156-157`) ; is-wired check
   (`boot_in_memory` bypasses it).
2. **#7 migration + step D together** — classify the ~100+ implicit-default
   conception domains → `:heki` (organs/plan/framework holding her state) or
   `:memory` (ephemeral) ; wire each hecksagon ; point heki config at the
   canonical `~/.heki/<deployment>` (the structural `resolve_info_dir` default
   change — step D / task #2 — lands here ; it is the env-free replacement for
   the rolled-back cutover). Consider a contract-driven generator if ~100
   hecksagons is too many. Examples/standalone stay on the memory default.
3. **Flip the conception `.world` to strict.** Only after every persisting
   conception domain is wired.

## Gate (before strict ships)
Cold-boot persistence-recovery (`rust/tests/persistence_recovery_test.rs`) ;
full behaviors corpus green ; `:memory` selects memory (new test) ; world-heki
inert without adapter (new test) ; strict-world unwired → boot error (new test) ;
non-strict unwired → memory (new test) ; full `cargo test`, no warnings.

## Discipline
Generated files (`command_dispatch.rs`, `behaviors_runner.rs`) are SNIPPET-
generated : edit `codegen/*_shape/snippets/*.frag`, then
`storehouse specialize <target> > <tracked file>` ; the golden gates
byte-equality. `runtime/mod.rs` is hand-maintained (its `specialize runtime`
golden is `#[ignore]`d, ~1496 lines stale — see `inbox/runtime-as-bluebook.md`,
a separate self-hosting arc Chris chose to pursue). Antibody blocks new
non-bluebook `.rs` : surface the block, let Chris approve the exemption per
file, never pre-write the marker.

## Queue note
The grammar / parser-in-bluebook arc (kernel-interpreter, conceiver-as-bluebook,
parser-in-bluebook cards) is a SEPARATE active line still queued here. This card
is newer so `ls -t` surfaces it first ; Chris picks which arc resumes next.
'
