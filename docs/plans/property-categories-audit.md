# Property and category audit

Hecks' guarantees are held by properties over generated histories and by category tests that
loop over a closed vocabulary or every example domain, instead of an example spec per case. This
note records the audit that chose what to replace, what was added, which example specs were
deleted and the mutation each one's replacement was shown to kill, and what is still pending.

## What already existed

- **The property battery.** `lib/hecks/fuzzing/properties.rb` and `properties/*.rb`; the list is
  `Properties::PROPERTY_NAMES` in `properties/catalog.rb`, each mapped to the language features it
  answers for. It runs over `Fuzzing::SequenceGenerator` histories replayed by `Fuzzing::Replay`
  (`spec/fuzzing/properties_spec.rb`), with a hand-built failing history per property.
- **Self-consistency.** `Fuzzing::SelfConsistency` folds each touched journal into a fresh store
  and compares it with the live one (rehydration), folds it twice (idempotency), and round-trips
  value objects and sagas. Its own failing cases are in `spec/fuzzing/self_consistency_spec.rb`.
- **Store parity.** `Fuzzing::PersistenceParity.diff` replays one sequence on two adapters and
  diffs instances, events, refusals, queries, sagas and reactions.
- **The fuzzer and mutate.** `hecks fuzz_run.fuzz` sweeps generated sequences; `hecks
  fuzz_run.mutate` mutates a domain's own bluebook (drop a given, flip a comparison, retarget a
  transition) and asks whether the battery, the corpus and the behaviors notice. It mutates
  domains, not the runtime, so runtime mutations in this audit were injected by hand.
- **The conformance corpus.** `spec/corpus/*.json` and `spec/corpus/semantics/*.json`, held to
  frozen expectations on Ruby (`spec/conformance_corpus_spec.rb`, `spec/semantics_corpus_spec.rb`)
  and Rust (`spec/rust_conformance_spec.rb`, the `:io` half of the semantics corpus spec).
- **Drift specs.** `spec/glossary_spec.rb`, `spec/diagrams_spec.rb`, `spec/ir_golden_spec.rb`,
  `spec/reference_golden_spec.rb`, the projected table specs, and the deploy goldens.
- **The role probe.** `Projections::Site::RoleProbe` synthesizes arguments for every role-gated
  command; `spec/site_roles_spec.rb` drives it against a live host.

## Closed sets a category test can loop over

| Set | Source | Looped by |
|---|---|---|
| Refusal kinds | `DomainRefusal` in `vocabulary.bluebook`, `Runtime::DOMAIN_REFUSALS` | `spec/categories/refusal_kinds_spec.rb` |
| Mutation ops | `MutationOp`; `CommandBuilder::FIELD_EFFECTS` for field writes | `spec/categories/mutation_ops_spec.rb` |
| Query comparators | `QueryComparator` | `spec/categories/query_comparator_kinds_spec.rb` |
| Dispatch order | `AggregateDispatchOrder`, `EntityDispatchOrder` | `spec/vocabulary_conformance_spec.rb`, `spec/runtime/argument_gate_order_matrix_spec.rb` |
| Doors | `Bluebook::Hecksagon::DRIVING_ADAPTERS`, plus the forms app | `spec/doors/*_spec.rb` |
| Persistence adapters | `lib/hecks/adapters/driven/*.adapter` declaring `port "persistence"` | `spec/fuzzing/properties/every_domain_spec.rb`, `spec/categories/era_read_through_spec.rb`, `spec/ports/persistence_contract_spec.rb` |
| Projection kinds | `Projector.registered_by_category` | `spec/categories/projection_kinds_spec.rb` |
| Era fixtures | `spec/fixtures/eras/*.bluebook` | `spec/categories/era_read_through_spec.rb` |
| Example domains | `Corpus.members(:example)` | the four specs `spec/categories/coverage_spec.rb` lists |

`spec/categories/coverage_spec.rb` places every vocabulary table, door, store and projection
category: each is looped by the spec named for it or left out with the reason, so a new member
fails there until it is placed.

## Candidates found

Grouped by the property or category that would cover them. Kept outright: the behaviors files,
the conformance and semantics corpora, drift and exact-output specs, real-infrastructure specs
(Postgres locks and eras, the Rust host, deploy, chaos) and tooling and CLI specs.

- **Mutation ops:** the `spec/mutation_*_growth_spec.rb` family, `spec/mutation_spec.rb`,
  `spec/mutation_arithmetic_absent_current_spec.rb`, `spec/runtime/entity_list_mutations_spec.rb`.
  These are feature pins from the hecksagain migration, not fuzzer regression pins.
- **Queries:** `spec/query_comparators_spec.rb`, the `spec/query_none_in_state_*` family,
  `spec/query_null_vo_argument_spec.rb`, `spec/query_paging_agreement_spec.rb`.
- **Lifecycle, identity, invariants:** `spec/lifecycle_value_scalar_growth_spec.rb`,
  `spec/identifier_numeric_coercion_growth_spec.rb`, `spec/banking_state_machine_spec.rb`,
  `spec/entity_invariant_spec.rb`.
- **Doors and roles:** single examples in `spec/runtime/authorization_spec.rb`,
  `spec/adapters/driven/governance_authorization_spec.rb`, `spec/driving_adapters/cli_runner_spec.rb`,
  `spec/forms/app_spec.rb`, `spec/storehouse_spec.rb`.
- **Refused means unchanged:** single examples in `spec/runtime/ensures_spec.rb`,
  `spec/runtime/memory_execution_plan_spec.rb`, `spec/runtime/command_rules_spec.rb`,
  `spec/runtime/entity_list_replace_identity_spec.rb`, `spec/runtime/outbox_spec.rb`,
  `spec/runtime/dry_run_spec.rb`, `spec/pizzas_spec.rb`, `spec/computed_sets_spec.rb`.
- **Journal rebuild and stores:** single examples in `spec/adapters/driven/memory_history_spec.rb`,
  `spec/adapters/driven/memory_nested_spec.rb`, `spec/adapters/banking_matrix_spec.rb`.
- **Era read-through:** `spec/runtime/attribute_absence_spec.rb`, `spec/runtime/hydrate_defaults_spec.rb`.

## What was added

| Guarantee | Where |
|---|---|
| A refusal leaves no trace: records, journal, events, reactions, saga advances and outbox rows | `Properties.refusals_leave_no_trace` (`lib/hecks/fuzzing/properties/refusals.rb`), recorded by `Replay::RefusalTrace`; `spec/fuzzing/properties/refusals_spec.rb` |
| Every refusal kind is raised by a real dispatch and leaves no trace | `spec/categories/refusal_kinds_spec.rb`, fixture `spec/fixtures/refusal_kinds/` |
| The same steps give the same outcomes and records through Ruby, the CLI, MCP and JSON | `spec/doors/door_equivalence_spec.rb`, `spec/support/doors.rb` |
| Every role-gated command refuses another role through Ruby and MCP alike | `spec/doors/role_enforcement_spec.rb` |
| Records rebuilt from the journal equal the store; Memory, SQLite and Postgres agree; refusals leave no trace, on every example domain | `spec/fuzzing/properties/every_domain_spec.rb` |
| Records written under an earlier era read through, or the boot refuses the shape | `spec/categories/era_read_through_spec.rb` |
| A write that crashes before commit leaves nothing | `spec/categories/write_atomicity_spec.rb` |
| Every mutation op on both engines and at entity level | `spec/categories/mutation_ops_spec.rb` |
| Every query comparator answers its pinned rows, agrees with the reference, and matches SQLite | `spec/categories/query_comparator_kinds_spec.rb`, fixture `spec/fixtures/query_comparators/` |
| Every domain projection runs on every example domain | `spec/categories/projection_kinds_spec.rb` |
| Every action, rule, stage and role appears in the projections meant to show it | `spec/categories/completeness_spec.rb`, `spec/support/domain_names.rb` |
| Every closed set is placed | `spec/categories/coverage_spec.rb` |

The refusal property was itself shown to fire: with the runtime mutated to save a record before
its ensures and invariants are checked, the fixture's post-mutation refusals each report "changed
instances, journal".

## Pending, and why

- **Rust host role checks.** `rust/host` submit paths dispatch with role `None` (`api.rs:384`,
  `api.rs:444`, `web.rs:2014`; host security review 2026-10-22, open HIGH finding), and no spec
  harness drives the host. Pending in `spec/doors/role_enforcement_spec.rb`.
- **Memory is not atomic.** `Memory#transaction` only yields, so a crash after `save` keeps the
  record and its journal entry although Memory advertises `:atomic_put`. Pending in
  `spec/categories/write_atomicity_spec.rb`.
- **The event log is not taken back on a crash.** On SQLite and Postgres the record, journal and
  outbox roll back, but `runtime.events` keeps the crashed write's event. Pending there too.
- **SQLite has no `none_in_state`.** `sql_query_builder.rb` raises `ArgumentError` rather than
  answering. Pending in `spec/categories/query_comparator_kinds_spec.rb`.

## Found along the way

- **A role-gated command with no caller.** MCP refuses it; the Ruby API runs it, since it checks
  a role only once a caller is bound, and the CLI runner and the forms app take no role at all.
  Pinned in `spec/doors/role_enforcement_spec.rb` so a change to either side is a decision.
- **A blank identity in a door's NotFound.** An entity command routed by `to:` whose entity is
  absent is refused with the entity's identity left blank, where Ruby names it. Pinned in
  `spec/doors/door_equivalence_spec.rb`.
- **The forms app serves no entity command routes**, so the JSON door is held to aggregate commands.
- **The unbundled launcher and json 3.** `exe/hecks` runs without Bundler and loads json 3, which
  refuses `quirks_mode:`; the translation string parser passed it, so a domain whose edges hold a
  string literal could not load through the launcher. Fixed by dropping the keyword.
- **A fuzz boot rebinds only bound chapters.** `IsolatedBoot` with `adapter: :sqlite` leaves a
  chapter with no hecksagon on Memory, so a parity run on it compares Memory with Memory. The
  every-domain spec checks the binding before it trusts a parity result.
- **A store with no eras reshapes a breaking bump silently.** That is by design
  (`spec/runtime/era_check_spec.rb`); only an era-holding store refuses it.

## Deleted, with the mutation each replacement kills

Each mutation was injected in-process by monkeypatching the runtime, then run against the old
example (which failed under it) and the replacements. An example was deleted only when a
replacement failed under the same mutation; otherwise it stayed. "Corpus" is the Ruby half of
`spec/semantics_corpus_spec.rb`; "battery" is `spec/fuzzing/properties_spec.rb`.

| Deleted | Mutation | Killed by |
|---|---|---|
| `spec/mutation_clamp_growth_spec.rb` (file) | clamp never caps at the max; never lifts to the min; moves an in-range value; refuses a never-set field | `mutation_ops_spec` entity-fixture outcome; corpus `numeric_effects_absent_target_and_operand` |
| `spec/mutation_value_wrap_asymmetry_growth_spec.rb` (file) | a never-set current not read as zero; a literal amount not wrapped | corpus `numeric_effects_absent_target_and_operand`, `delegated_event_dropped_on_parent_refusal` |
| `spec/runtime/entity_list_mutations_spec.rb` (file) | entity append, remove, increment, multiply and clamp each a no-op; append replacing the list; a bare-sets list left as raw hashes | `mutation_ops_spec` entity-fixture outcome and recompute; `refusal_kinds_spec`; corpus `remove_all_matches`; battery |
| `spec/query_comparators_spec.rb` (file) | eq never matching; ne answering as eq; gt as gte and back; lt as lte and back; in testing one member; contains ignoring lists | `query_comparator_kinds_spec` pinned rows and SQLite parity |
| `spec/query_none_in_state_lifecycle_spec.rb` (file) | none_in_state reading a hardcoded `:state` key instead of the target's lifecycle field | `query_comparator_kinds_spec` none_in_state rows |
| `mutation_remove_growth_spec.rb`: removes a matching element | aggregate remove a no-op | corpus `remove_all_matches` |
| `mutation_float_arithmetic_growth_spec.rb`: Float increment | increment refusing a Float | corpus `numeric_int_float_compare`, `float_overflow_is_fault` |
| `mutation_arithmetic_absent_current_spec.rb`: increment, decrement and multiply on an absent current | no unwrap for each op; an absent-path decrement that adds | corpus `numeric_effects_absent_target_and_operand` |
| `mutation_append_bare_symbol_growth_spec.rb`: order preserved | append at the head | corpus `collection_guard_toppings`, `events_and_reactions_order` |
| `mutation_spec.rb`: the till arithmetic and literal-append examples | VO increment a no-op; decrement adding; literal not wrapped; an Integer field taking a String; a literal append resolved as an argument | corpus (several fixtures); `refusal_kinds_spec` |
| `lifecycle_value_scalar_growth_spec.rb`: a transition from a state never held | `from:` never checked | `refusal_kinds_spec` LifecycleRefused |
| `banking_state_machine_spec.rb`: the balance model over seeded traces | decrement applied as increment | `refusal_kinds_spec` InvariantViolation and no-trace |
| `entity_invariant_spec.rb`: an empty note refused; a genuine note accepted | entity invariants skipped; the verdict inverted | `refusal_kinds_spec` |
| `runtime/authorization_spec.rb`: no caller, matching role, mismatched role | refuse with no caller bound; the role check inverted; the role gate never raising | `role_enforcement_spec`; `door_equivalence_spec`; `refusal_kinds_spec` |
| `governance_authorization_spec.rb`: gates a role-checked Banking dispatch | the role check inverted | `role_enforcement_spec`, `door_equivalence_spec` banking |
| `storehouse_spec.rb`: role by string equality; no caller refused; the qualified spelling refused; any matching string accepted | role never bound; role mangled; the no-role gate removed | `role_enforcement_spec` (MCP against Ruby, no-role refusal); `door_equivalence_spec` MCP |
| `pizzas_spec.rb`: the instance untouched when a command is refused | the refused write lands before the refusal | `refusals_spec`; `refusal_kinds_spec`; `every_domain_spec`; battery |
| The "nothing changed" assertion in `ensures_spec.rb`, `memory_execution_plan_spec.rb` and `command_rules_spec.rb`; the examples keep their wording checks | save before re-raising EnsuresNotMet; overwrite on a duplicate create; reset the lifecycle on a refusal | `refusal_kinds_spec`; `every_domain_spec`; `refusals_spec`; `door_equivalence_spec` |

Kept, because no replacement failed under the mutation the old example catches: clamp, remove
and Float behavior the corpus never reaches (Float multiply and decrement, removing a value never
added, the ambiguous multi-numeric refusal); the build-time checks (an undeclared `sets` target,
bare-symbol normalization); entity-level and Heki-backed `none_in_state`, a target with a plain
`state`, nil query arguments, paging, numeric identities, value-object lifecycle fields,
auto-minted ledger ids, optional fields inside an entity invariant; `actor_id`, the
authorization port's own answers, audit lines, Storehouse's dry runs and the exact output of the
CLI and forms doors; dry runs in general, a refused list replace, a computed fault, field order
on journal rebuild, the banking matrix's absolute values and Heki, and every "record predates a
field" read in `attribute_absence_spec.rb` and `hydrate_defaults_spec.rb`.

## Limits of what was added

- **Dry runs are not exercised.** `SequenceGenerator` draws no dry-run steps by default, so
  `dry_runs_leave_no_trace` holds vacuously over generated histories, and it compares events and
  instances but not the outbox.
- **The era spec reads only the written fields.** It shows a `same_*` or additive shape reads
  through and a breaking one is refused; it does not read a field a record predates.
- **Reference agreement shares the comparator table.** Memory and the reference engine use one
  comparator table, so `query_answers_match_reference` catches only a fault in one engine; the
  pinned rows in `spec/fixtures/query_comparators/steps.json` are what catch a shared one.
