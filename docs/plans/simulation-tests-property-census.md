# Slice 5 of simulation-tests.md: census of the properties and the replay traces

Status: research, nothing changed in `lib/` or `rust/`. Base: `origin/main` at `c01f06b98`. Date: 2026-11-06.
**R** marks what I read in this tree; **I** marks what I inferred and did not confirm.

## How the count was made

`find lib/hecks/fuzzing/properties -type f | wc -l` gave **25**. The plan says 24; it counted the
files at the time it was written, and `ls` lists 25 names, all `.rb`, no subdirectory. The table below has
one row for each of the 25. The replay side is `lib/hecks/fuzzing/replay.rb` and the 10 files in
`lib/hecks/fuzzing/replay/` (`find ... -ipath '*replay*'`, which also matches
`properties/lifecycle_and_replay.rb`, already a row below). I read every file in both sets; a row's
evidence line is a line I read in the file, quoted in short.

## The classes, as I applied them

- **(a) pure over wire history.** Reads only `events`, `refusals`, `instances`, `queries` rows (with
  `instances_at`) and the declared IR (`history[:bluebooks]`), and recomputes with no call into the booted
  runtime. A tag **E** says the recompute leans on Ruby code the engine also uses (`Ports::Query::InMemory`,
  `Runtime::Value`, `Bluebook::Expression::Evaluator`). It is still class (a), but it judges Ruby with Ruby until
  slice 0 decides the shared evaluator (ADR 0188 step 2).
- **(b) re-runs Ruby's interpreter or reads `runtime`.** The history field it reads was produced by
  calling Ruby's `CommandInterpreter`, `CommandRules`, `Dispatcher`, `reference_query` or `query_page`, or the
  property boots and dispatches itself.
- **(c) reads Ruby-only traces.** Reactions with their `trigger`/`delivered`/`for_row`, outbox rows, saga and
  policy dispatch bindings, saga instances, cross-domain deliveries, refusal snapshots that include them.
- A file holding properties of several classes takes the **highest** letter (a < b < c) and says so; the
  property table further down gives the exact split.
- **none** marks a file that checks nothing (a data table).

## Table 1: the 25 files

| File | Class (module) | Evidence line | What a kernel-only version needs |
|---|---|---|---|
| `aggregation_recompute.rb` | (a) **E** (`AggregationRecompute`) | `eligible_rows(bluebook, instances, ...)` reads `asked.fetch(:instances_at)`; folds via `Ports::Query::InMemory.comparable` | `instances_at` per query step (the `instances` step exists, `cli.rs:594`); a decision on the shared comparable |
| `bulk_parity.rb` | (b) (`BulkParity`) | `runtime = Hecks.boot(copy, environment: nil)` then `Bulk::Sweep.new(runtime.registry, plan)` | the kernel has no bulk run: `grep -n bulk` over `serve.rs` and `cli.rs` finds nothing (**R**). Needs a bulk step on serve, or the property is dropped and bulk stays Ruby-only |
| `catalog.rb` | none (`PROPERTY_NAMES`, `FEATURE_COVERAGE`) | `PROPERTY_NAMES = [ :lifecycle_values_are_declared, ...` | not a check; the list is what slice 6 edits as properties are rewritten |
| `corrections.rb` | (a) (`Corrections`) | `events.first(index)` ... `earlier[:name] == corrected_event` | `events` as the kernel emits them (`cli.rs:378`) with `aggregate` and `id`, plus the IR |
| `cursor_walks.rb` | (b) (`CursorWalks`) | `history.fetch(:queries)` ... `asked[:pages]`, recorded by `@runtime.query_page(question, after:, page_size:)` | a paged query step; `grep -n page` over `serve.rs`/`cli.rs` finds none (**R**). The comparison itself is pure once pages exist |
| `dispatch_and_mutations.rb` | (c) (`DryRuns`, `DispatchAndMutations`) | `history.fetch(:saga_dispatches, [])` and `history.fetch(:policy_dispatches, [])` | the binding each saga or policy dispatch resolved (`with_spec`, `event_payload`, `memory`) on the wire; its `DryRuns` half needs before/after instance snapshots around `dry_run` steps (serve has `snapshot`, `instances`, `dry_run`); its `mutations_match_recompute` half needs the mutation trace below |
| `group_by_recompute.rb` | (a) **E** (`GroupByRecompute`) | `eligible_rows(bluebook, asked.fetch(:instances_at), ...)`; `Runtime::Value.materialize_unwrapped(state)` | as `aggregation_recompute.rb`, plus `Runtime::Value` re-implemented or shared |
| `grouped_reduction_recompute.rb` | (a) **E** (`GroupedReductionRecompute`) | `REDUCERS = Hecks::Vocabulary.rows("Reducer")` (declared rows) | as `aggregation_recompute.rb`; the reducer rows are data already |
| `guaranteed_by_construction.rb` | none (`GUARANTEED_BY_CONSTRUCTION`) | `"Aggregate#attributes" => "every field's pattern/closed-set/type passes through Value.build's one coercion entry point"` | nothing; but each entry cites a Ruby file as its reason (`value/coercion.rb`, `command_rules/emission.rb`). Under the kernel the reasons must cite its code or the claim goes unchecked (**I**) |
| `guards.rb` | (b) (`Guards`) | `history.fetch(:guard_checks)` ... `check[:recomputed_refused] == check[:actual_refused]`; trace from `Runtime::CommandRules.new(...).enforce_givens` | `authorize_scopes_or_refuses` and `guard_refusals_are_declared` are (a) (read `queries`, `refusals`, IR). The third needs the guard check as a metamorphic property: a refusal with `kind` GivenNotMet leaves the store as before, and the same step on a store where the given holds is admitted |
| `invariants_and_aggregation.rb` | (c) (`InvariantsAndAggregation`) | `history.fetch(:saga_instances)` (from `registry.saga_instances`) and `history.fetch(:fan_outs)` (built from `@runtime.reactions`) | split: `stored_records_...`, `aggregation_...`, `group_by_...` are (a) **E**; `sagas_rehydrate_cleanly` needs live saga instances on the wire (the kernel emits `saga_snapshot`, `cli.rs:394`); `fanout_...` needs the reaction log with `for_row` and the pre-event snapshot |
| `lifecycle_and_replay.rb` | (c) (`LifecycleAndReplay`) | `history.fetch(:sagas)` ... `entry[:advanced]`; also `first = Replay.call(domain_path, steps, adapter: adapter)` | `lifecycle_values_are_declared` is (a). `saga_advances_...` reads `sagas`, which the kernel does emit (`cli.rs:391`); the entry shape (`advanced`, `from`, `to`) is unchecked (**I**). `replay_is_deterministic` is (b): it runs `Replay.call` twice, so it becomes "same seed, two sessions, same history" on serve (layer 2 of the plan) |
| `mutation_recompute.rb` | (b) (`MutationRecompute`) | `Runtime::Value.for_attribute(context.aggregate, attribute, raw)` and `Runtime::Instance.default_for(aggregate, attribute)` | a recompute that owns its own coercion and defaults, or the plan's metamorphic form (append then remove is the identity); the kernel already reports `mutations` (`cli.rs:382`) |
| `outbox.rb` | (c) (`Outbox`) | `Array(history[:outbox_traces])` ... `row[:status]`, `row[:delivery_id]` | the kernel has no outbox on the wire (`grep outbox` on `cli.rs` is empty, **R**); a row's `status` and `consumer` would be a new field, or the property is Ruby-only because delivery is inline by contract in the kernel (**I**) |
| `piece_invariants.rb` | (a) **E** (`PieceInvariants`) | `Bluebook::Expression::Evaluator.call(invariant.canonical, state)` over `history[:instances]` | `instances` plus an evaluator; the single place layer 3 of the plan has no independent judge |
| `policy_wiring.rb` | (c) (`PolicyWiring`) | `Array(history[:reactions])` ... `reaction[:trigger]`, `reaction[:delivered] == true` | the kernel's `reactions` log (`cli.rs:386`) names `policy` and `on`; whether it names `trigger` and `delivered` I did not confirm (**I**). Needs both, plus `events` |
| `query_rows.rb` | (a) **E** (`QueryRows`) | `snapshot.instances.filter_map` with `Ports::Query::InMemory.holds?(resolved, held, args)` and `QuerySpecification::HopPath` | `instances_at` and the hop path resolution as data |
| `querying.rb` | (b) (`Querying`) | `asked[:rows] == asked[:reference_rows]`, the second from `@runtime.reference_query`; `Runtime::QueryInterpreter.new(nil).send(:normalize_args, ...)` | `query_answers_match_reference` compares two Ruby interpreters and has no kernel form: drop it or replace it with the corpus `asks/` set. `paging_offset_partitions_correctly` is (a) **E**. The file also mixes in `CursorWalks` |
| `read_model_names.rb` | (a) (`ReadModelNames`) | `(history[:bluebooks] \|\| {}).each_value.flat_map { ... bluebook.read_models` | reads the IR only, not the history; becomes a static check in the front end (`ModelCheck`) |
| `read_models.rb` | (a) **E** (`ReadModels`) | `ask[:instances_at].filter_map { \|key, state\| ... }` and `ask[:rows].first` | `queries` rows and `instances_at`; head composition recomputed from references |
| `references.rb` | (a) (`ReferenceReading`, `References`) | `preceding.any? { \|earlier\| earlier[:aggregate] == key && earlier[:id].to_s == id }` | `events` with `aggregate`, `id`, `payload` and the IR |
| `refusals.rb` | (c) (`Refusals`) | `REFUSAL_TRACE_PARTS = %i[instances journal events reactions sagas outbox]` | before and after snapshots including journal, reactions, sagas and outbox. Serve can do `instances` and `snapshot` around a refused step; `journal` (`Ports::Persistence::AppendOnly` entries) and `outbox` have no kernel counterpart (**I**). A byte-identical `snapshot` before and after is the plan's form |
| `role_checks.rb` | (b) (`RoleChecks`) | `history[:role_checks]` with `grants`, built by `Runtime::Dispatcher.new(registry).query(verb, actor_id: ...)` | grants read back through a serve `query` step on the authorization domain, and the `Unauthorized` outcome in `refusals` |
| `set_transform_parity.rb` | (b) (`SetTransformParity`) | `Bulk::Sweep.new(runtime.registry, plan, set_transform: set_transform)` | adapters `sqlite` and `postgres` only; the kernel does no I/O (ADR 0012), so it has no kernel form and stays with the Ruby adapters |
| `tenant_scope.rb` | (a) **E** (`TenantScope`) | `instances = history.fetch(:instances)` ... `Ports::Query::InMemory.comparable(state[field])` | `instances` and the IR's `authorization` tenant |

## Totals, by file

25 files = **10** (a) + **7** (b) + **6** (c) + **2** none.

- (a): `aggregation_recompute`, `corrections`, `group_by_recompute`, `grouped_reduction_recompute`,
  `piece_invariants`, `query_rows`, `read_model_names`, `read_models`, `references`, `tenant_scope`.
- (b): `bulk_parity`, `cursor_walks`, `guards`, `mutation_recompute`, `querying`, `role_checks`,
  `set_transform_parity`.
- (c): `dispatch_and_mutations`, `invariants_and_aggregation`, `lifecycle_and_replay`, `outbox`,
  `policy_wiring`, `refusals`.
- none: `catalog`, `guaranteed_by_construction`.

Four of the (a) files are helpers (`aggregation_recompute`, `group_by_recompute`,
`grouped_reduction_recompute`, `query_rows`) that other files mix in, and the class totals by file overstate
the weight of (b) and (c) because a mixed file takes the worst letter.

## Table 2: by property (the finer count)

The 26 names in `PROPERTY_NAMES` (`catalog.rb`), then four checks that are not in that list (`catalog.rb` names
none of them; three boot for themselves, and the cursor walk is a `Querying` mixin).

| # | Property | File | Class | Trace it reads |
|---|---|---|---|---|
| 1 | `lifecycle_values_are_declared` | `lifecycle_and_replay` | (a) | `instances` |
| 2 | `saga_advances_follow_declared_handlers` | `lifecycle_and_replay` | (c) | `sagas` |
| 3 | `query_answers_match_reference` | `querying` | (b) | `queries[:reference_rows]` |
| 4 | `guard_refusals_are_declared` | `guards` | (a) | `refusals` |
| 5 | `sagas_rehydrate_cleanly` | `invariants_and_aggregation` | (c) | `saga_instances` |
| 6 | `fanout_dispatches_once_per_matching_row` | `invariants_and_aggregation` | (c) | `fan_outs` |
| 7 | `aggregation_matches_recompute` | `invariants_and_aggregation` | (a) **E** | `queries`, `instances_at` |
| 8 | `stored_records_satisfy_declared_invariants` | `invariants_and_aggregation` | (a) **E** | `instances` |
| 9 | `group_by_matches_recompute` | `invariants_and_aggregation` | (a) **E** | `queries`, `instances_at` |
| 10 | `paging_offset_partitions_correctly` | `querying` | (a) **E** | `queries`, `instances_at` |
| 11 | `lifecycle_guard_and_given_violations_are_refused` | `guards` | (b) | `guard_checks` |
| 12 | `authorize_scopes_or_refuses` | `guards` | (a) | `queries` |
| 13 | `commands_respect_tenant_scope` | `tenant_scope` | (a) **E** | `instances` |
| 14 | `dispatch_binding_fidelity` | `dispatch_and_mutations` | (c) | `saga_dispatches`, `policy_dispatches` |
| 15 | `mutations_match_recompute` | `dispatch_and_mutations` | (b) | `mutation_traces` |
| 16 | `dry_runs_leave_no_trace` | `dispatch_and_mutations` | (b) | `dry_run_traces` |
| 17 | `validation_agrees_with_dry_run` | `dispatch_and_mutations` | (b) | `dry_run_traces` |
| 18 | `refusals_leave_no_trace` | `refusals` | (c) | `refusal_traces` |
| 19 | `corrections_reference_an_emitted_event` | `corrections` | (a) | `events` |
| 20 | `outbox_rows_match_reactions` | `outbox` | (c) | `outbox_traces` |
| 21 | `policy_reactions_follow_declared_wiring` | `policy_wiring` | (c) | `reactions`, `events` |
| 22 | `declared_undelivered_policies_stay_undelivered` | `policy_wiring` | (c) | `reactions`, `events` |
| 23 | `references_resolve_to_earlier_records` | `references` | (a) | `events` |
| 24 | `role_checks_agree_with_grants` | `role_checks` | (b) | `role_checks` |
| 25 | `read_model_names_resolve_uniquely` | `read_model_names` | (a) | IR only |
| 26 | `read_model_heads_compose_from_references` | `read_models` | (a) **E** | `queries`, `instances_at` |
| 27 | `cursor_walk_yields_the_unpaged_rows` | `cursor_walks` | (b) | `queries[:pages]` |
| 28 | `replay_is_deterministic` | `lifecycle_and_replay` | (b) | runs `Replay.call` twice |
| 29 | `bulk_runs_match_hand_dispatch` | `bulk_parity` | (b) | boots twice, `Bulk::Sweep` |
| 30 | `set_transform_matches_row_by_row` | `set_transform_parity` | (b) | boots twice, sqlite or postgres |

Totals by property: 30 = **12** (a) + **10** (b) + **8** (c). Of the (a) twelve, seven are tagged **E**.
Slice 6's rewrite list is therefore the 18 in (b) and (c); the 12 in (a) need only a wire that carries
`instances`, `instances_at` and `events`.

## Table 3: the replay traces (`Replay::Session#observed_history`, `replay/observation.rb`)

| History key | Built in | Produced by | Class | On the kernel's wire today (**R**, `cli.rs:377-391`) |
|---|---|---|---|---|
| `instances` | `Replay.snapshot_instances` | `runtime.repository(...).all` | (a) | yes, `instances` |
| `events` | `Observation#events` | `@runtime.events` | (a) | yes, `events` |
| `refusals` | `Session#record_refusal` | `rescue *Runtime::DOMAIN_REFUSALS` | (a) | yes, `refusals` |
| `queries` (`rows`, `args`, `error`) | `ReadOnlySteps#ask_declared` | `@runtime.query` | (a) | yes, `queries` |
| `queries[:instances_at]` | `ReadOnlySteps` | `Replay.snapshot_instances` per ask | (a) | no per ask; serve has an `instances` step to call between |
| `queries[:reference_rows]` | `ReadOnlySteps#reference_answer` | `@runtime.reference_query` | (b) | no |
| `queries[:pages]` | `ReadOnlySteps#cursor_walks` | `@runtime.query_page` | (b) | no |
| `dry_runs`, `validations` | `ReadOnlySteps`, `ValidationReports` | `@runtime.dry_run?`, `validate` | (b) | yes, `dry_runs`, `validations` |
| `dry_run_traces` | `ReadOnlySteps#dry_run` | `state_snapshot` before and after, plus `validate_facts` | (b) | no (the before/after halves) |
| `guard_checks` | `replay/guard_check.rb` | `Runtime::CommandRules#enforce_givens`, `CommandInterpreter#normalize_args` via `send` | (b) | no |
| `mutation_traces` | `replay/mutation_trace.rb` | `CommandInterpreter#normalize_args`, `Runtime::Value` | (b) | partly: `mutations` (`aggregate`, `id`, `operation`, `state`) |
| `role_checks` | `replay/role_check.rb` | `Runtime::Dispatcher#query` of the authorization provider | (b) | no |
| `reactions` | `@runtime.reactions` | the reaction log | (c) | yes, `reactions` and `reactions_per_step`; `policy`, `on` seen, `trigger`/`delivered` unchecked |
| `sagas` | `@runtime.sagas` | the saga log | (c) | yes, `sagas`; shape unchecked |
| `saga_instances` | `Observation#saga_instances` | `registry.saga_instances` | (c) | yes, `saga_snapshot` (`cli.rs:394`), the end-of-run state; `sagas` is the transition log |
| `fan_outs` | `replay/fan_out.rb` | `Evaluator.call(policy.where, ...)` plus a pre-event snapshot and `@runtime.reactions` | (c) | no |
| `refusal_traces` | `replay/refusal_trace.rb` | `instances`, `journal` (`AppendOnly#entries`), `events`, `reactions`, `sagas`, `outbox` counts | (c) | no |
| `outbox_traces` | `Session` | `@runtime.outbox.rows` | (c) | no |
| `saga_dispatches`, `policy_dispatches` | `Observation` | `@runtime.saga_dispatches`, `policy_dispatches` | (c) | no |
| `cross_domain` | `Observation` | `@runtime.cross_domain_deliveries` | (c) | yes, `cross_domain_reactions` (`policy`, `on`, `target_domain`, `target_verb`, `payload`) |
| `bluebook`, `bluebooks` | `registry.first_bluebook`, `registry.bluebooks.dup` | the parsed IR | declared data | n/a: the IR is an input, not a trace |
| `self_consistency` | `SelfConsistency.check(@runtime, history)` | Ruby only | (b) | no |

## What this says for slice 6

- **R** Twelve of 30 properties already ask nothing of Ruby beyond the data a wire can carry; seven of those
  recompute with Ruby helpers (**E**), so they stay a Ruby-judges-Ruby risk until slice 0 settles the evaluator.
- **R** The kernel wire already carries `reactions`, `sagas`, `cross_domain_reactions`, `dry_runs`,
  `validations` and `mutations`. Many class (c) properties may need a field added rather than a new trace;
  the shape of each entry is the check slice 6 starts with.
- **R** Four things have no kernel counterpart at all: bulk runs, cursor pages, the outbox and the append-only
  journal. Those properties (`bulk_runs_...`, `set_transform_...`, `cursor_walk_...`, `outbox_rows_...`, and the
  journal part of `refusals_leave_no_trace`) either wait for a kernel feature or stay with the Ruby engine
  until step 6 of ADR 0188.
- **I** `query_answers_match_reference` cannot be rewritten: it compares Ruby's two interpreters.
