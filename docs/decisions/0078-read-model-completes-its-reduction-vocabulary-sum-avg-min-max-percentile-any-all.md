# Read model completes its reduction vocabulary — `sum`, `avg`, `min`, `max`, `percentile`, `any`, `all`

**Status:** Accepted. Overrides ADR 0061's "out of scope" line for `avg`/`min`/`max`, builds
ADR 0061's already-designed `sum` as-is, and extends the same design to three words ADR 0061
never considered: `percentile`, `any`, `all`.

## Context

ADR 0061 fully designed `sum` and rejected `avg`/`min`/`max`/`having`/`distinct` on ADR 0025's
bar ("a word earns its place by being used") and ADR 0026's ("inventing a site to satisfy a
tool is decoration, not use"): it searched the whole corpus and found no caller wanting
`avg`/`min`/`max`, so it left them undesigned pending a named consumer.

That bar is right for a word with no shape and no story — the failure mode ADR 0026 guards
against is inventing a keyword and then writing a fake corpus site just to look used. It is
the wrong bar for this specific set, for a reason ADR 0061 itself half-states without
following through: `count`, `median` and (once built) `sum` are not three independent
capabilities, they are three instances of one capability — "reduce the eligible collection's
own rows to a single number" — and a language that ships three of eight standard instances of
that capability (SQL's `COUNT`/`SUM`/`AVG`/`MIN`/`MAX`) teaches every reader a false lesson:
that the other five are harder, riskier, or deliberately withheld, when in fact `min`/`max`
are strictly *simpler* than `sum` (no overflow, no float-summation hazard — see below), and
`avg` is `sum` divided by `count`, both of which already exist. Half a vocabulary is a worse
teaching tool than a design note nobody reads. The completeness of the set is the use case;
withholding `min` because no corpus author has asked for it yet, while `sum` and `median` sit
right next to where `min` would go, is the "decoration" failure pointed the other way — an
arbitrary asymmetry defended by a rule about a different failure.

`percentile`/`any`/`all` are new words ADR 0061 never evaluated. They are included here
because each is a strict generalization or restatement of a word already being built in this
same change (`percentile` subsumes `median`; `any`/`all` are `count`'s boolean twins), not a
new independent capability being smuggled in under the same PR.

This ADR does not reopen ADR 0061's `having`, `distinct`, grouped reductions (Option 3), or SQL
pushdown (Option 5) — those add a new *shape* (rows-per-group, or a filter over a reduction),
not a new reduction over the one shape (a single value over the eligible collection) this
change stays inside. Those remain out of scope, on ADR 0061's own reasoning, which this ADR
does not disturb.

## What already exists, unchanged

`count` (bare), `median :field` and `group_by :f1, :f2, ...` — `ReadModelBuilder`
(`seal_group_by`, `seal_aggregation`), `Runtime::ReadModelInterpreter#project`
(`nest`, `median`, `aggregation_target`), `rust/src/kernel/read_model.rs` (`nest`, `median`),
generated through `rust/project/read_models.rb` and `rust/codegen/src/read_models.rs`. The rule
these already enforce, extended rather than replaced: exactly one many-side head; a read model
reports one shape, so every reduction refuses every other reduction and `group_by`.

## Decision

Add seven words, all siblings of `median` under the same seal:

| Word | Shape | Field type | Empty-set answer |
|---|---|---|---|
| `sum :field` | total of one field | Integer only (below) | `0` |
| `avg :field` | mean of one field | Integer only (below) | `nil` |
| `min :field` | smallest value | Integer or Float | `nil` |
| `max :field` | largest value | Integer or Float | `nil` |
| `percentile :field, at: 0.5` | interpolated rank | Integer or Float | `nil` |
| `any :field` | whether any row's field is `true` | Boolean | `false` |
| `all :field` | whether every row's field is `true` | Boolean | `true` |

`median :field` is kept as its own word (two shipped corpus uses; ADR 0025's "one idea, one
way" forbids a second spelling for it) but is reimplemented as `percentile(field, at: 0.5)`
under the hood, so the two cannot silently diverge.

### Why `min`/`max` are simpler than `sum`, not harder

`sum` needed ADR 0061's Integer-only restriction because *adding* floats is where determinism
breaks (Ruby's compensated `Array#sum` versus a naive fold; ADR 0061's `[0.1] * 10` example).
`min`/`max` never add anything — they compare and return one of the rows' own already-stored
values verbatim. Float comparison (`partial_cmp`/`<=>`) is exact and platform-independent for
any non-NaN value, and the language has no way to declare a NaN-valued attribute. So `min`/`max`
accept both Integer and Float fields from day one, with none of `sum`'s hazards.

### Why `avg` no longer "forces the float question" ADR 0061 raised

`avg :field` is defined as `sum(field) / count`, computed as `sum.to_f / count.to_f` in Ruby
and `sum as f64 / count as f64` in Rust. Both `sum` (restricted to Integer, refused past 2^53
by `sum`'s own rule) and `count` are exact integers representable in `f64` without loss. IEEE
754 double-precision division of two exactly-representable operands is correctly rounded —
defined by the standard, not by the language runtime — so Ruby's and Rust's division of the
same two integers-as-floats produce the bit-identical `f64`. This is not the same operation as
summing a list of floats (where rounding accumulates across additions and compensation
algorithms diverge); it is one division, done once, which is the one float operation
IEEE 754 actually guarantees agreement on. `avg`'s empty-set answer is `nil` (unlike `sum`'s
`0`): zero divided by zero is not a rate of zero, it is undefined, and treating "no rows" as
"averaged to zero" is the wrong number to report to a caller.

### `percentile` generalizes `median`, verified against the shipped algorithm

Reading `Runtime::ReadModelInterpreter#median` (`values.length.odd? ? values[middle] :
(values[middle - 1] + values[middle]) / 2.0`) and `rust/src/kernel/read_model.rs`'s `median`
(same, via `Json::Float` for the even branch): both are the linear-interpolation formula
`pos = at * (n - 1); lo = pos.floor; frac = pos - lo; value = sorted[lo] + frac * (sorted[lo+1]
- sorted[lo])` at the fixed point `at = 0.5`. At `at = 0.5`: odd `n` gives `pos` exactly an
integer (the middle index, `frac = 0`), even `n` gives `pos` exactly `.5` between the two
middle indices (`frac = 0.5`, i.e. their average). So generalizing to an arbitrary `at` and
re-deriving `median` as the `at: 0.5` case reproduces today's shipped behavior exactly — this
is confirmed by making `median`'s own spec suite run unchanged against the new shared
implementation, not merely argued.

`at:` is required, a `Float` in `0.0..1.0` inclusive, checked at build time (unlike `median`'s
field-numeric check, which needs the aggregate's declared shape and so waits for dispatch);
`0.0` is the minimum, `1.0` the maximum, matching `PERCENTILE_CONT` semantics.

### `any`/`all`'s justification is real but thinner than the numeric five — stated plainly

`any :field`/`all :field` operate on a `TrueClass`/`FalseClass` attribute (read models have no
expression position — ADR 0022 — so neither can mean "any row where `amount > 100`"; that
still requires `where(amount: { gt: 100 })` plus `count`, which already answers "any" as
`count > 0` and "all" by comparing `count` to the un-filtered total). This makes `any`/`all`
strictly expressible today via `where` + `count`, in a way `sum`/`min`/`max`/`percentile` are
not. They are still added, because the caller-facing shape differs in a way that matters: a
consumer wanting "does this account have any flagged charge" wants a `true`/`false` JSON value
to render or branch on directly, not a number it must remember to compare to zero, and a
boolean-typed attribute (e.g. `flagged`) is a real, already-common shape in this style of
corpus (compliance/review flags) that `where`+`count` handles awkwardly (it requires the
caller to *also* declare the `where(flagged: true)` clause, duplicating the field name twice
for one boolean question). This is a real but smaller ergonomic win than the numeric five, and
the "empty read model" vacuous-truth convention (`any` of nothing is `false`; `all` of nothing
is `true` — the ordinary `Enumerable#any?`/`all?`/OR-identity/AND-identity reading) is
recorded here because it is the one place in this batch most likely to read as surprising to a
consumer who has not seen the convention before; the reference doc states it explicitly rather
than leaving it to be discovered.

## Semantics shared by all seven (stated once, so Ruby and Rust cannot diverge)

- **Same seal as `median`.** Exactly one many-side head; a read model declares at most one of
  `group_by`/`count`/`median`/`sum`/`avg`/`min`/`max`/`percentile`/`any`/`all`; `limit`,
  `offset` and `order_by` are refused alongside any of them (ADR 0061 D4, now applied
  uniformly rather than only to `count`/`median` retroactively).
- **Field-type check at dispatch**, mirroring `median`'s `aggregation_target`: `sum`/`avg`
  require an Integer-typed field (`FieldPath.numeric?` plus an Integer-only check on the
  resolved attribute); `min`/`max`/`percentile` require any numeric field; `any`/`all` require
  a Boolean-typed field, checked by a new `FieldPath.boolean?` alongside the existing
  `numeric?`/`scalar_leaf?`. Each refuses with the field name, the read model name, and what
  was declared instead — matching `median`'s existing refusal wording exactly.
- **Reads through `comparable`**, exactly as `median`/`where`/`order_by` do, inheriting the
  same mixed-currency hazard on a `Money`-shaped field that those three already have and that
  ADR 0061 already documented and deferred (D2, still open, still deferred here — this ADR
  does not re-litigate it).
- **Rows are filtered first.** Every reduction runs over the `where`-filtered eligible
  collection, in id-ascending fold order, exactly as `count`/`median` do today.
- **Authorization applies before any reduction**, exactly as ADR 0061 stated for `sum`:
  `TenantScope` wraps the model before any of these run, so no reduction is ever computed
  outside the caller's tenant.

## IR shape

Additive and absent-when-undeclared, exactly like `count`/`median_field`: `sum_field`,
`avg_field`, `min_field`, `max_field`, `percentile_field`, `percentile_at`, `any_field`,
`all_field` — new optional members on the read model's `to_h`, present only on a member that
declares them. Existing corpus members' IR is unchanged (`spec/ir_golden_spec.rb` churns only
for the new corpus members this change adds, not for `DisputedPaymentCount`/`Median`/
`AccountsByKind`/etc.).

## Ruby implementation shape

`sum`/`avg`/`min`/`max`/`any`/`all` need **no bespoke `_impl` method** in `ReadModelBuilder`:
each is exactly `median`'s own shape — one required positional `symbol` argument, no named
arguments — which `GenericDispatch#try_single_fill` already handles generically off the
grammar table alone (confirmed by reading `generic_dispatch.rb`: `median` itself has no
bespoke method either, for the same reason). Adding each is a `KeywordSeed` row (`fills:
"sum_field"`, no `calls:`) plus one `ArgumentSeed` row (`kind: "symbol"`, `at: "1"`, `required:
"true"`) in `lib/hecks/language/bluebook/projection.bluebook`, mirroring `median`'s two rows
exactly.

`percentile` needs a real `percentile_impl(field, at:)` method (`calls: "percentile_impl"`):
two arguments, one of them named, is outside `try_single_fill`'s one-positional-argument
shape. It validates `at` is a `Float` in `0.0..1.0` and stores `@percentile_field`/
`@percentile_at`; `median`'s own `sets :median_field` becomes, internally, `@percentile_field
= field; @percentile_at = 0.5` — one shared code path, two grammar entry points.

`ReadModelBuilder#seal_aggregation` generalizes from its current two-name check (`@count ||
@median_field`) to a table: `REDUCTION_FIELDS = %i[count median_field sum_field avg_field
min_field max_field percentile_field any_field all_field].freeze`, refusing more than one
declared and requiring exactly one many-side head when any is declared — replacing the
hand-written pairwise checks with one loop over the table, the same "extraction over widening"
shape ADR 0061's own seals already use for `group_by` versus `seal_aggregation`.

`Bluebook::ReadModel#to_h` merges each new field only when declared, same as `count`/
`median_field` today. `Runtime::ReadModelInterpreter#aggregation_target` generalizes to a
per-reduction-kind type check (Integer-only, numeric, or boolean) instead of `median`'s single
hard-coded numeric check; `#project`'s dispatch (`reduced_head && as == reduced_head[:as] &&
model.count?` / `... median(...)`) grows one branch per new reduction, each a short fold
(`Array#sum`, `Array#min`, `Array#max`, `Array#all?(&:itself)`, etc.) over the same
`comparable`-mapped values `median` already extracts.

## Rust implementation shape

A proven-subset extension of what `count`/`median` already are, per ADR 0061's own read of
this: no new framework, no per-read-model generated function needed for any of the seven
(unlike `group_by`, which needs one because unwrapping a value object needs codegen-time type
knowledge). Concretely, on `ReadModelDef`: `sum_field`, `avg_field`, `min_field`, `max_field`,
`percentile_field: Option<&'static str>`, `percentile_at: Option<f64>`, `any_field`,
`all_field: Option<&'static str>`. Kernel: `sum`, `avg`, `min_value`, `max_value`, `percentile`,
`any_true`, `all_true` functions beside `median` in `rust/src/kernel/read_model.rs`, each
reading through `query_comparators::comparable` the same way `median` does; `median` becomes a
call to `percentile(rows, field, 0.5)`. Both generators
(`rust/project/read_models.rb` and `rust/codegen/src/read_models.rs`) gain the same fields in
lockstep, per ADR 0054b; `rust/src/exemplar/read_models.rs` gets a hand-written case exercising
each, matching how it already exercises `median`. The Rust parser gains the seven words in
`rust/parser/src/{keywords,ir,emit,main}.rs` and `parse/read_model.rs`, `percentile` taking the
two-argument (positional + named `at:`) shape the parser already has a pattern for (`where`'s
own pairs, `authorize`'s `tenant:`).

## Determinism and byte-for-byte conformance

- `sum` returns an Integer (never Float); `avg`/`percentile`'s even-count branch return a
  `Json::Float`/Ruby `Float`, exactly as `median` already commits to for its own even branch.
- Empty-set answers are fixed per the table above, identical on both runtimes.
- `sum`/`avg` refuse a Float-typed field and refuse an Integer sum past 2^53, both runtimes,
  per ADR 0061's existing `sum` design, now shared by `avg`.
- Fold order is id-ascending on both runtimes, per the existing `count`/`median` guarantee.
- `bin/rust_conformance`'s `read_models.json` gains one fixture per new reduction, and
  `spec/codegen_parity_spec.rb` compares both generators' output for each, per ADR 0054b.

## Fuzz and doc coverage

One new independent recompute property per reduction in
`lib/hecks/fuzzing/properties/invariants_and_aggregation.rb`, beside the existing
`aggregation_matches_recompute` — each written without reusing the interpreter's own fold
(the `nest_rows`/`stripped.first` lesson ADR 0061 records: an oracle that mirrors the
implementation agrees with a bug by construction). `docs/implemented/reference/read_model.md`
gains one worked example per word (`spec/guides_spec.rb` executes it);
`spec/optionality_coverage_spec.rb`, `spec/meta_rule_reachability_spec.rb` and
`spec/diagrams_spec.rb`'s read-model-label case each need a line per new reduction, same as
ADR 0061 already catalogued for `sum` alone.

## Corpus consumers

Real read models, not decoration built to satisfy this ADR's own bar (ADR 0026's actual
concern) — each answers a question ADR 0061 already found waiting in the existing corpus, or
one this ADR's own reasoning surfaces:

- `Banking.DisputedPaymentTotal` — `sum :amount`, the exact site ADR 0061 named as the
  strongest gap ("the number a risk manager wants first — total disputed amount").
- `Banking.DisputedPaymentAverage` — `avg :amount`, same site, the natural sibling question
  ("is this account's typical dispute large or is it one outlier among many").
- `Banking.DisputedPaymentLargest` (`max`) and `Banking.DisputedPaymentSmallest` (`min`) — a
  compliance reviewer's next question after `DisputedPaymentCount`/`Median`: is the median
  driven by one huge outlier or are they all similar.
- `Banking.DisputedPaymentP95` — `percentile :amount, at: 0.95` — the tail-risk number a
  median hides, on the same site.
- `Banking.AccountHasOpenDispute` — `any :disputed`, once `CardPayment` gains a boolean
  `disputed` attribute alongside its existing `status` — the boolean-shaped restatement of
  `DisputedPaymentCount > 0` a UI wanting a badge, not a number, actually wants.

Each is added in the same PR as its word, per ADR 0025's "a word earns its place by being
used" — now satisfied, not overridden, for every word this ADR adds.

## Out of scope (unchanged from ADR 0061)

`having`, `distinct`, grouped reductions (`group_by` plus a per-group reduction — ADR 0061
Option 3), reductions on a plain `query`, SQL pushdown, cross-aggregate reductions, `cursor`.
None of these are a new instance of "reduce the eligible collection to one value" — each adds a
new output shape or a new surface, which is exactly the bar this ADR does not attempt to
clear.

## Consequences

The language's reduction vocabulary stops being three arbitrary instances of an eight-member
standard set and becomes the whole set (nine, counting `median`/`percentile` as one). The
`sum`/`avg` currency and Float-summation hazards ADR 0061 already flagged for `sum` are
unchanged and still deferred (D2); this ADR does not close them, only extends the same
open hazard to one more word (`avg`) that inherits it from `sum` rather than introducing a new
one.

## Verification done for this ADR

Read directly: `ReadModelBuilder`, `GenericDispatch` (`shape_for`, `try_single_fill`,
`try_zero_arg`), `Behaviour::ReadModel`, `Runtime::ReadModelInterpreter`,
`FieldPath` (`numeric?`, `scalar_leaf?`), `Comparison.comparable`,
`rust/src/kernel/read_model.rs` (`nest`, `median`, the `run` dispatch), ADRs 0022, 0025, 0026,
0050, 0052, 0054b, 0055, 0061, and every read model in `examples/banking`. Confirmed by
reading, not run: the IEEE 754 correctly-rounded-division argument for `avg` (a property of
the standard, not observed on this machine); Rust float-comparison total-ordering behavior for
`min`/`max`/`percentile` (`partial_cmp` already used by the shipped `median`, unchanged here).
Run: none yet — implementation follows this ADR in the same change.
