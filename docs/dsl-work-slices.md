# DSL work slices

The work decided in [ADR 0025](decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md) and [ADR 0026](decisions/0026-the-language-uses-everything-it-declares-and-what-it-does-not-use-is-a-sub-language.md), re-cut from a sequence into slices that can be worked in parallel by separate agents.

Both ADRs sequence for one worker, with the prerequisites front-loaded. That ordering is still correct about *dependencies*, but it says nothing about *collisions*, which is what actually decides whether two agents can run at once.

## How to run a slice

**One worktree per slice.** Every slice edits `lib/hecksagain/language/bluebook/syntax.bluebook`, so slices sharing a checkout will trip over each other. Use `isolation: "worktree"`.

**A slice is vertical.** It is not done until all six of these move together:

1. the grammar rows in `syntax.bluebook` for the words it owns
2. the builder(s) that read those words
3. the runtime that acts on them
4. every corpus call site — `examples/`, `lib/hecksagain/framework/`, `spec/fixtures/`
5. the hand-written prose in `docs/reference/*.md` (the generated regions regenerate; the prose between markers does not)
6. specs, including one that sees each new refusal *fail*

**Done means the gate passes**, not that the tests you wrote pass:

```
bundle exec rspec              # 1691 with CI=true, 1563 without
./bin/model_check
./bin/doc_coverage
./bin/fuzz --seeds 3 --steps 8
```

`bin/doc_coverage` is the one that catches an unfinished slice: remove a word without removing its reference section, or add one without an example, and it refuses.

## The shared-file rule

`syntax.bluebook` is 960 lines and partitioned into contiguous runs by `context:` — Aggregate 15 rows, Query 14, ReadModel 17, Command 8, Entity 8, Policy 5, ProcessManager 6, and so on. Two slices touching different contexts touch different regions, so conflicts are textual and mechanical rather than semantic.

The exception worth knowing: **`attribute` rows appear under Aggregate, Entity, and Command**. Any slice changing the attribute vocabulary touches three regions and will conflict with the slices that own those contexts. That is why S3 is sequenced alone.

## Wave 0 — prerequisites

These two block most of what follows and are independent of each other, so run them together.

### S0a — `shadow_parse` reads a legacy grammar

**Why first:** frozen era text is parsed by the *live* DSL — `shadow_parse` is a plain `Kernel.eval` run at boot, at mint, and during tamper detection, and the text is SHA-256-locked to `held_digest`. **No word can be removed until history can still be read.**

**Owns:** `runtime/era_guard.rb`, `bluebook/meta_validator.rb`, whatever flag the builders consult.
**Blocks:** S1, S3, S4, S5 — every slice that deletes a spelling.
**Done when:** a bluebook using `identified_by { number.value }` refuses in live source and parses in `shadow_parse`, with a spec covering both directions.

### S0b — the scoped-constant bridge

**Why first:** verified by probe — once a facade exists, `Widget` is a real module, so `Widget::Make` hits the default `Module#const_missing` and the shim is never reached. Without this, first-class events and command references cannot be spelled as constants at all.

**Owns:** `facade/surface.rb`, `bluebook/dsl/const_shim.rb`.
**Blocks:** S6, S7, and the `admits:` half of S3.
**Watch:** the scenario that broke the earlier attempt was two domains in one registry. Write that test first.
**Done when:** `Account::Debit` and `admits: Account::LedgerDirection` both resolve during declaration, and a real facade method with a colliding name still works.

## Wave 1 — parallel, no shared context

| slice | owns | corpus blast radius |
|---|---|---|
| **S1 — identity** | `identified_by` rows (Aggregate, Entity); `attribute_collector.rb`, `aggregate_builder.rb`, `entity_builder.rb`, meta-validator identity judge | 12 constant-form + 4 block-form declarations |
| **S2 — references** | `reference_to`/`has_*` rows (Aggregate, Entity); `naming.rb`, `hop_path.rb`, `handle.rb`, `query_interpreter.rb`, `sql_query_builder.rb`, `bluebook_builder.rb` | **243 `reference_to` sites, every dispatch call, every hop path** — by far the largest |
| **S4 — reads** | Query + ReadModel rows; `query_builder.rb`, `read_model_builder.rb` | 5 `report` → `read_model`, 3 inert-word deletions |
| **S5 — commands** | Command rows; `command_builder.rb`, `mutation_applier.rb` | 143 `then_set` → `sets`, 35 redundant `to:` |
| **S8 — role → Governance** | `role` row (Command); `command_rules/authorization.rb`, `hecksagon_builder.rb` | 103 `role` declarations, plus a `uses_framework` line per hecksagon |
| **S11 — absence** | `era_guard/shape_diff.rb`, `command_rules/admissibility.rb` (`GuardState`) | none — pure runtime |

**S1, S2, S4, S5, S8, S11 can all run at once.** S2 is the one to start earliest regardless of who takes it: 243 call sites means it will finish last whatever else happens.

S8 is security-affecting — **add the new check before removing the old one**, and land it behind its own commit so it can be reverted alone.

## Wave 2 — depends on Wave 1

| slice | depends on | note |
|---|---|---|
| **S3 — attributes** (type position, closed sets) | S0a | Touches `attribute` rows under three contexts. **Run alone**, or accept conflicts with S1/S5. |
| **S6 — events first-class** | S0a, S0b | Largest design change. `emits`, `on`, `trigger`, `with:`, saga `dispatch`, the IR, both runtimes. |
| **S10 — rules** (aggregate `invariant`, lifecycle guards, named preconditions) | S0a, S9 | Removes 35 `"account is open"` givens and dedups 45 `"customer is active"`. |
| **S9 — entity/aggregate shared vocabulary** | S0a | Also fixes `hop_path.rb:191`, which asserts entities have no `reference_to` while `EntityBuilder#reference_to` exists. |

## Wave 3 — depends on Wave 2

| slice | depends on |
|---|---|
| **S7 — reactions** (one state-machine vocabulary, first-class command refs) | S0a, S0b, S6 |
| **S12 — `projects` and the boundary rule** | S0a, S6, S7, S10, S11 |
| **S13 — coverage standard** (corpus uses / written exemptions for the 11) | everything |

**S12 is the one to read carefully before starting.** It deletes `References#dereference`, migrates 49 givens, and has to build its own adapter-agnostic rebuild plus a `ProjectionAbsent` refusal — there is no existing backfill path to inherit, and the failure mode without one is every command on every pre-existing record refusing with a message that points away from the cause.

## ADR 0026 slices

Independent of the 0025 waves except where noted.

| slice | note |
|---|---|
| **S14 — `Status` becomes a lifecycle** | Self-contained, small, high value: `bin/model_check` currently calls the language "clean" because it declares no states at all. Good first slice for a new agent. |
| **S15 — the `Paging` sub-language** | `limit`/`offset`/`cursor`/`nulls` leave the core grammar. Needs the attachment mechanism (a sub-language declares where it attaches) built first. Conflicts with **S4** — both own Query/ReadModel rows. Sequence after it. |
| **S16 — the self-use gate** | Model on `spec/fuzzing/meta_domain_coverage_spec.rb`. **Will fail the day it is written** — that is the point. Run last, after S14/S15 have reduced what it reports. |
| **S17 — `Member`/`Dispatch`/`Handler` become entities** | The largest single item in either ADR. Moves records inside their parent aggregate; the meta-domain's readings and reconstruction read them as separate aggregates today. **Do not parallelise this with anything.** |

## What cannot be parallelised

- **S3 against S1/S5** — shared `attribute` rows across three contexts.
- **S15 against S4** — both own the Query and ReadModel grammar regions.
- **S17 against anything** — it restructures the meta-domain that every other slice's validation runs through.
- **Anything against Wave 0** — S0a and S0b change the rules every later slice is written against.

## Open items not yet sliced

Recorded so they are not lost, each small enough to fold into a related slice:

- `domain_port` vs `port` — third instance of the `report`/`read_model` split; the DSL word is `port`, the construct/docs/IR say `domain_port`. Fold into S13.
- `Domain::Aggregate.X.Y` is ambiguous between an entity command and a port operation (`dispatcher.rb:67`). Latent — pizzas' `PaymentGateway` is the only port. Fold into S9.
- `parent` is undocumented — a piece reaches its aggregate through it and it appears in no reference page. Fold into S9.
- ADR `0008` says `report` is the business-facing spelling of a read model, which `0025` reversed. Neither records the supersession. Fold into S4.
- The adapter-agreement gate's first stage (`parallel_rspec`) flakes roughly one run in six — one process dies with no reported failure, losing ~132 examples. Unrelated to this work; blocked a push once.
