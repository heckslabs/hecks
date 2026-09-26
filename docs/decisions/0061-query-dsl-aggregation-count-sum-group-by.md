# Query-DSL aggregation (`count` / `sum` / `group_by`) — the gap is narrower than reported, and one part of it is a defect

**Status:** Proposed — draft for review. Design only; nothing in this document
is implemented, and no code changes with it. It answers item 11 of an outside
production-readiness review ("the query DSL has no aggregation"), whose premise
turns out to be partly stale, and it recommends against adding the full
`count/sum/avg/min/max` set. The one thing it recommends doing now is a bug fix,
not a new word.

## Context

### What the docs say, and what is true

[`docs/future-features.md`](../future-features.md) ("Query-DSL aggregation"),
[`docs/query-dsl.md`](../query-dsl.md) ("Proposed additions — not implemented")
and the README's known-gaps list all say the query language computes nothing.
That stopped being true before this ADR. `read_model` declares three reductions
today, all shipped, all running on Ruby and on the generated Rust runtime:

| Word | Shape | Real use | Shipped in |
|---|---|---|---|
| `count` (bare) | the eligible many-side head's row count | `Banking.DisputedPaymentCount` | ADR 0052 |
| `median :field` | median of one numeric field, `nil` on no rows | `Banking.DisputedPaymentMedian` | ADR 0052 |
| `group_by :f1, :f2` | the head's rows nested into a Hash, one level per field | `Banking.AccountsByKind`, `ConsoleSettings.Styles`, `ConsoleSettings.Curated` | ADR 0050 |

The seals live in `ReadModelBuilder` (`seal_group_by`, `seal_aggregation`): exactly
one many-side head; a read model reports one shape, so `count`, `median` and
`group_by` refuse each other. The interpreter is
`Runtime::ReadModelInterpreter#project` (`nest`, `median`, `aggregation_target`);
the Rust twin is `rust/src/kernel/read_model.rs` (`nest`, `median`), generated
through `rust/project/read_models.rb` and mirrored in `rust/codegen`.

So what is actually missing is:

1. **`sum`, `avg`, `min`, `max`.** Nothing adds numbers.
2. **A `group_by` that reduces.** `group_by` nests rows; it does not count or sum
   per group. See the defect below.
3. **Reductions on a plain `query`.** `query` returns rows; only `read_model`
   reduces.
4. **Pushdown.** Every reduction runs in-process over the whole loaded table
   (`ReadModelInterpreter` skips the SQLite `query_read_model` hatch when
   `group_by`/`count`/`median` is declared, and Postgres has no such hatch at all).
5. **More than one reduction per read model.**

### A defect found while investigating: `group_by` silently drops rows

`nest` keeps one row per full key path (`rest.empty? ? stripped.first : ...`; Rust's
`nest` does `group.into_iter().next()`). The interpreter's own comment calls this
"a real, deliberate scope limit": it assumes the `group_by` path uniquely identifies a
row. Nothing checks the assumption. Probed against the current tree
(in-memory adapter, three rows, `group_by :group` where two rows share `g1`):

```text
{"g1"=>{:ref=>"w1", :id=>"w1"}, "g2"=>{:ref=>"w3", :id=>"w3"}}
```

`w2` is gone, with no refusal and no warning. That is the failure this repo's
CONTRIBUTING names as the interesting one: the declaration says "group these" and
the runtime quietly returns a subset. It is invisible to the fuzzer too, because
`group_by_matches_recompute`'s oracle (`nest_rows`, `invariants_and_aggregation.rb`)
re-implements the same `stripped.first` and so agrees with the runtime by
construction. The corpus avoids it only by accident of choice: `AccountsByKind`
groups by `:kind, :number` (its own doc comment says two fields "prove the
nesting nests", and `number` is the identity), and `Styles`/`Curated` group by a
full identity. The question a branch manager actually asks — "how many accounts of
each kind" — cannot be written as `group_by :kind` without losing accounts.

## Where the corpus needs more (evidence for ADR 0025's "a word earns its place by being used")

ADR 0025 admits a word by use; ADR 0026 warns that inventing a site "to satisfy a tool"
is decoration, not use. I searched `examples/*`, `spec/corpus/*`, and the framework
and language bluebooks (`lib/hecks/framework`, `lib/hecks/language`) for read
models and queries, and for consumer code that computes over their results.
The corpus is declarative, so "hand-computed" here mostly means "a declaration
whose own description promises a number that its shape cannot deliver". Honest
ranking, strongest first:

1. **Disputed-payment exposure** — `examples/banking/bluebook/customer_and_compliance_views.bluebook`.
   `DisputedPaymentCount` and `DisputedPaymentMedian` are one root, one
   `where(status: "disputed")`, one reduction each. Their own comment says a
   manager scanning accounts for risk "wants a single NUMBER per account". The
   number a risk manager wants first — total disputed amount — is the one sibling
   with no word. [`docs/query-dsl.md`](../query-dsl.md) named exactly this ("total
   disputed amount", "count of open disputes") as the motivating case before
   `count`/`median` shipped; `count` and `median` answered two of the three.
2. **Accounts per kind** — same file, `AccountsByKind`. Described as "every
   account the bank holds, sorted into what kind it is, then by its own number".
   The corpus comment gives "prove the nesting actually nests" as the reason for the
   second key; the effect is that no two rows ever collide. A count per kind is a
   grouped reduction (`group_by` plus `count`) and is not expressible.
3. **A customer's position** — same file, `CustomerPortfolio` ("a customer's
   cross-account position"). It gathers seven raw collections; a consumer wanting
   the position as a number has to sum `balance` over `accounts` itself, since the
   read model returns rows only. No consumer in this repo does that sum, so this is
   a promise in a description, not a workaround anyone wrote.
4. **Console dashboard stat cards** — `lib/hecks/framework/bluebook/console_settings.bluebook`,
   `Overview.Stat` (`label`, `collection`, `field`, `where_json`). A stat card is a
   filtered count or a per-field figure over a collection, and its own comment says
   the consumer (`PresentationConfig`) evaluates it in Ruby. That consumer is not in
   this repository, and the bluebook does not say whether `field` means count-of or
   sum-of, so this is a plausible fourth site, unverified.
5. **Statement balances** — `examples/banking/bluebook/statements.bluebook`.
   `Statement.Generate` takes `opening_balance` and `closing_balance` from the caller
   instead of deriving them from `Account`'s ledger. That is a sum, but over a
   `list_of` inside one aggregate (the expression sublanguage), not over a query
   result. Adjacent; out of scope here.

What I did not find: any use of `avg`, `min` or `max`; any corpus site that wants
`having` or `distinct`; any consumer code in this repository that hand-sums or
hand-groups a query result. Whatever consumers exist (the review is from outside)
live in other repositories. By ADR 0025's bar, `avg`/`min`/`max` have no use and
should not be added. `sum` and a grouped count have a real *shape* gap in shipped
corpus declarations, but no consumer asking for either, and adding a corpus read
model in the same change to "use" `sum` would be the decoration ADR 0026 rejects.

## Options

| # | Option | Words added | Fixes the defect | Corpus use | Cost | Verdict |
|---|---|---|---|---|---|---|
| 0 | Do nothing; correct the three stale docs | 0 | no | n/a | trivial | Necessary, not sufficient |
| 1 | Refuse a non-unique `group_by` leaf, on Ruby and Rust | 0 | yes | all 3 existing `group_by` sites unaffected (unique keys) | small, both runtimes | **Recommended now** |
| 2 | Option 1 plus `sum :field`, sibling of `median` | 1 | yes | site 1 shape gap; no consumer yet | ~15 touch points (below) | Design ready; gated on a named consumer |
| 3 | Option 2 plus a grouped reduction (`group_by` + `count`/`sum` per group) | 0 to 1 | yes, by making collisions meaningful | site 2; no consumer yet | new output shape, new Rust codegen | Later, gated on a consumer |
| 4 | Full `count/sum/avg/min/max` + `group_by` + `having` (the review's ask) | 4+ | incidental | `avg/min/max/having` have none | large; float determinism problem | Rejected (ADR 0025) |
| 5 | SQL pushdown (`SELECT count(*)`, `SUM`, `GROUP BY`) in `SqlQueryBuilder` | 0 | no | perf, not language | adapter agreement risk | Separate ADR, only if measured |

## Decision

**Adopt Option 1 now. Design Option 2 (below) so it can be built without another
design round, and build it only when a real consumer asks for `sum`. Treat Option 3
the same way. Do not add `avg`, `min`, `max`, `having` or `distinct`.**

Option 1 detail, so the human can veto it as stated: at dispatch time, if two
rows reach the same full `group_by` key path, refuse with a message naming the
read model, the key path and the colliding ids ("`AccountsByKind` groups by :kind,
but 2 rows share kind = savings; add a distinguishing field or use a grouped
count"). This is data-dependent — a read model that worked on Tuesday can refuse on
Wednesday when a second row appears — which is unpleasant, but a loud refusal at the
first collision is strictly better than a silently truncated answer, and it moves the
mistake to the first request rather than never. A build-time check is not possible:
uniqueness of a key over rows is not a fact the declaration holds, except when the
key path covers the aggregate's identity, in which case the builder can accept it
without a runtime check. The refusal wording goes through `RefusalWording` like every
other runtime refusal, so Ruby and Rust share one sentence. The fuzz oracle
`nest_rows` must stop mirroring `stripped.first` and instead assert the refusal, or
the property keeps agreeing with the bug.

## Design for Option 2 (`sum`), ready to build

### Syntax candidates

Constraint: ADR 0025's one-idea-one-way. `count` and `median` already exist as
sibling words inside `read_model`; any candidate that adds a second spelling for them
must retire them.

| Candidate | Example | Assessment |
|---|---|---|
| **A. Sibling word** | `sum :amount` next to `median :amount` and bare `count` | Matches the shipped vocabulary exactly (`median`'s argument grammar, the same `FieldPath.numeric?` seal). One word, one way. Costs a word per reduction. **Chosen.** |
| B. One word, named function | `aggregate :sum, :amount` | Second spelling for `count`/`median` unless they are retired; retiring breaks two shipped corpus uses and every downstream bluebook for no new capability. Rejected. |
| C. Grouped block | `group_by :kind do count end` | The right shape for Option 3, and the only candidate that puts the reduction where its scope is visible. Not needed for Option 2; see Option 3. |
| D. Named output in an expression | `total: sum(amount)` | Read models have no expression position, and ADR 0022 keeps the expression grammar out of the read-model surface. Rejected. |

Proposed (not implemented):

```text
read_model "DisputedPaymentTotal" do
  description "The total amount of an account's own disputed card charges."
  reference_to Account
  include Account
  include CardPayment
  where(status: "disputed")
  sum :amount
end
```

### Semantics, all of them stated so Ruby and Rust cannot diverge

- **Same seal as `median`.** Exactly one many-side head; never combined with
  `count`, `median` or `group_by`; the field must be numeric per `FieldPath.numeric?`
  (a bare `Integer`/`Float`, or a value object carrying one numeric member), checked
  at dispatch like `median`.
- **Reads through `comparable`.** A value object with a numeric member reduces to that
  member, exactly as `median`, `where` and `order_by` already read it.
  **Currency hazard:** `Money` is `{cents, currency}`; `comparable` picks `cents` and
  drops `currency`, so `sum :amount` over mixed-currency rows silently adds dollars to
  euros. `median` and `order_by` already have this hazard. The language has no
  currency concept to check against, so v1 inherits it and documents it; tightening
  all three is a separate decision (see "Decisions for the human").
- **Empty and null.** Rows whose field is `nil` are skipped (as `median` does).
  `sum` of no rows is the Integer `0` (v1 admits only Integer fields, below), not
  `nil`: "no disputes" means zero exposure, where `median` has
  no answer to give. This departs from `median` on purpose and is decision D3 below.
- **Reduces the `where`-filtered set.** Today's `count` and `median` take the set *after* `limit`/`offset`/`order_by`
  too — by reading `project`, `count` on a read model that also declares `limit 5`
  answers at most 5. No corpus read model combines them, so the seal should refuse
  `limit`, `offset` and `order_by` alongside any reduction (`count`/`median` retroactively,
  `sum` from day one). This is part of Option 1's neighbourhood and is decision D4.
- **Integer sums are exact and Float sums are refused in v1.** Ruby integers are
  arbitrary-precision; the Rust kernel's `Json::Num` is an `f64`, exact only to 2^53.
  Ruby's `Array#sum` on Floats uses compensated (Kahan-Babuska) summation:
  `[0.1] * 10` sums to `1.0` with `sum` and `0.9999999999999999` with `inject(:+)`, so
  a Rust fold cannot match it byte for byte without porting the compensation. v1
  therefore admits `sum` only over Integer-typed fields, refuses a Float field at
  build/dispatch with a clear message, and refuses (rather than wraps) an
  Integer total beyond 2^53 so Rust and Ruby never disagree. `avg` would force the
  Float question (`1000 / 3.0 => 333.3333333333333`; float formatting parity is a
  second thing to prove), which is one more reason it has no place until a use
  appears.
- **Order.** Rows are folded in the head's row order: id ascending, which every
  adapter's `all` already guarantees (`ORDER BY id`, `InMemoryOrdering`) and Rust's
  `AggregateScan` matches. Integer sums do not depend on it; it is stated because a
  future Float or grouped variant would. One caveat I did not verify: Postgres
  `ORDER BY id` uses the database collation, Ruby and Rust compare bytes. For
  lowercase ASCII ids they agree; for mixed-case or punctuated ids they may not.
  This is an existing property of every id-ordered read, not something aggregation
  adds, and it is recorded here because first-occurrence `group_by` key order
  (Option 3) inherits it.

### IR shape

Additive and absent-when-undeclared, exactly like `count`/`median_field`
(`ReadModel#to_h` merges them "only when declared"): a new optional
`sum_field` string on the read model (`reductions[:sum_field] = @sum_field.to_s`).
Existing corpus members serialize identically, so `spec/ir_golden_spec.rb` does
not churn; only a member that declares `sum` gains the key. Self-hosted grammar:
one optional `sum_field` attribute and a `Sum` command in
`lib/hecks/language/bluebook/projection.bluebook` beside `Median`, plus the `word:`
and `keyword:` rows for context `ReadModel` (`fills: "sum_field"`), admitted through
the `proposed → admitted` lifecycle in the Extending Hecks guide.

### Ruby semantics on each adapter

The reduction is a fold in `ReadModelInterpreter`, over rows the adapter already
returned, so **all four adapters (Memory, Sqlite, Postgres, PostgresEra) agree by
construction**: none is asked to compute anything. That is the cost and the
guarantee. Every reduction loads the whole aggregate table (`read_repository.all`),
which is wrong at scale for `count` over a large `CardPayment` table. It is also why
no pushdown is proposed here: pushing `SUM`/`COUNT` into `SqlQueryBuilder` would give
three engines three chances to disagree on integer overflow (SQLite raises, Postgres
widens to `numeric`), `NULL` versus `0` on an empty set, and collation. If it is ever
measured to matter, it needs its own ADR and a differential case in
`spec/adapters/query_agreement_spec.rb` (hand-computed oracle, per that file's own
rule) before it lands.

### Rust codegen

A proven-subset extension, not a new framework — ADR 0052 already showed `count`/
`median` needed none. Concretely: `ReadModelDef.sum_field: Option<&'static str>`;
a kernel `sum(rows, field) -> Json` beside `median`, reading through
`query_comparators::comparable` and returning `Json::Num`; `sum_field` added to
`READ_MODEL_BARE_KEYS` and an arm in `aggregation_skip_reason` (numeric,
Integer-typed, real attribute); both generators (`rust/project/read_models.rb` and
`rust/codegen/src/read_models.rs`) in lockstep, since ADR 0054b keeps both and
`spec/codegen_parity_spec.rb` compares them. The Rust parser needs the word in
`rust/parser/src/{keywords,ir,emit,main}.rs` and `parse/read_model.rs`. A read model
that declares an unsupported shape keeps refusing with "is not generated for this
domain", as the README already documents for other shapes. No hand-written per-model
Rust is needed (unlike `group_by`'s generated transform function), because `sum`
unwraps one declared field at runtime.

### Authorization and tenant scope

`authorize policy, tenant: :field` is applied before any reduction: `TenantScope`
wraps the model with a synthetic `eq` clause that `options_for` applies to the
eligible head, and `single_filtered_head_name` treats a declared tenant as making the
one many-side head eligible. So `count`, `median` and `sum` all see only the
caller's tenant, and a reduction must never be pushed below that clause (a reason
Option 5 needs its own review). There is no field-level or role-level read
authorization in the language, so an aggregate exposes no field the underlying rows
would not. One real limit: `group_by` keys are visible values, so a grouped count
across a tenant boundary would disclose which key values exist; Option 3 must apply
the tenant clause first, and the Rust generator already refuses `group_by` together
with `authorization`.

### Determinism and byte-for-byte conformance

- Result typing is part of the contract, as ADR 0052 established for `median`
  (`700` versus `700.0`): `sum` returns an Integer, never a Float, so the JSON is a
  bare number on both sides.
- Empty-set answer is `0` on both sides (decision D3).
- Integer overflow past 2^53 refuses on both sides (above).
- Fold order is id ascending on both sides (above).
- The differential harness has to compare query *content*: `bin/rust_conformance`
  once compared only `instances`/`events`/`refusals` (ADR 0050 found and fixed that
  gap). Any new reduction needs a fixture in `spec/corpus/rust_conformance/` and a
  case in `read_models.json` so the conformance spec exercises it.

### `model_check` and fuzz

- `bin/model_check` analyses lifecycles and sagas; it has no read-model checks, so
  aggregation adds nothing to it. If `having` ever arrives, unreachable-`having`
  is the natural static finding; not proposed.
- Fuzz gets one new recompute property beside `aggregation_matches_recompute`
  (`recompute_sum`, an independent left-to-right integer sum over `eligible_rows`),
  and the sequence generator's catalog needs to know the word. The recompute must be
  written independently of the interpreter; the `nest_rows` lesson above is what
  happens otherwise. The existing properties do not run against Postgres by default
  (`bin/fuzz --adapter postgres` is opt-in and slow), which is consistent with the
  reduction being adapter-independent.
- Doc surface: `bin/doc_coverage` requires a real reference section with a running
  example (`docs/implemented/reference/read_model.md`, executed by
  `spec/guides_spec.rb`), `spec/optionality_coverage_spec.rb` and
  `spec/meta_rule_reachability_spec.rb` each list the reductions and need a line, and
  `spec/diagrams_spec.rb`'s "labels a count read_model and a median read_model"
  case needs a `sum` sibling.

### Touch points (the cost of one sibling word)

`lib/hecks/bluebook/read_model.rb`, `dsl/read_model_builder.rb`,
`behaviour/read_model.rb`, `runtime/read_model_interpreter.rb`,
`language/bluebook/projection.bluebook`, `fuzzing/properties/invariants_and_aggregation.rb`,
`projector` diagram label, `rust/parser/src/{keywords,ir,emit,main}.rs` plus
`parse/read_model.rs`, `rust/src/kernel/read_model.rs`, `rust/project/read_models.rb`,
`rust/codegen/src/read_models.rs`, `rust/src/exemplar/read_models.rs`, the reference
page, and a corpus member. About fifteen files; that is what "a word" costs here, and
part of why it should wait for a consumer.

## Option 3 sketch (grouped reductions) — not designed to build

Candidate C above. `group_by :kind do count end` (or `group_by :kind` followed by a
reduction sibling) would change the leaf from "one row" to "a number per key":
`{"current" => 2, "savings" => 1}`. It reuses Option 1's collision refusal as the
non-reduced form. Open questions that a consumer should answer first: whether the
non-reduced `group_by` leaf should become an array of rows (a breaking output-shape
change for three shipped read models and their Rust output), whether more than one
reduction per read model is wanted (today's "a read model reports one shape" rule),
and key ordering (first occurrence, per Ruby `Hash#group_by`; Rust `nest` already uses
a linear scan for that reason).

## Out of scope

`avg`, `min`, `max` (no use); `having` and `distinct` (no use; `having` needs a
grouped reduction to filter); reductions on a plain `query` (a query returns rows;
`read_model` is where results are shaped); SQL pushdown (Option 5); Float sums;
currency-aware sums; cross-aggregate reductions (a sum over two many-side heads;
the single-head seal stays); the `Statement` balance derivation (an expression over a
`list_of`, not a query); `cursor` (still refused).

## Decisions for a human

- **D1.** Adopt Option 1 (refuse a colliding `group_by` leaf) now? The alternative is
  to leave `group_by` as documented and add a warning to the reference page. Data-
  dependent refusals are unpleasant; silent truncation is worse.
- **D2.** Currency: keep `sum` (and `median`, `order_by`) reading through `comparable`
  and document the mixed-currency hazard, or refuse a numeric read through a
  multi-member value object and require an explicit dotted path (`sum :"amount.cents"`)
  so the hazard is at least visible in the declaration?
- **D3.** Empty-set `sum` is `0`, not `nil`. Confirm, since it departs from `median`.
- **D4.** Refuse `limit`/`offset`/`order_by` alongside `count`/`median`/`sum`
  (recommended; `count` with `limit 5` currently answers at most 5, by reading the
  interpreter, not by a probe) or keep today's compositional reading?
- **D5.** Who is the named consumer for `sum`? Without one, Option 2 stays a design.
  Adding a `DisputedPaymentTotal` read model to `banking` to satisfy the gate is
  possible and is exactly the decoration ADR 0026 calls out.
- **D6.** Number and placement: this file is `0061` in `docs/decisions/`, the next
  free number across `docs/decisions/` and `docs/implemented/decisions/`
  (`0060` is taken there). Move to `docs/implemented/decisions/` only if a later
  PR implements any of it.

## Consequences

If Option 1 is taken: three docs stop lying (`future-features.md`, `query-dsl.md`,
the README known-gaps line), one silent-wrong-answer path becomes a loud refusal on
both runtimes, and the fuzz oracle stops sharing the bug. If Option 2 is later taken
on the terms above, the language gains one word whose semantics are pinned tightly
enough that a byte-for-byte Ruby/Rust comparison is a fixture, not an investigation.
If neither is taken, the only correction that matters is the documentation.

## Verification done for this ADR

Read directly: `ReadModelBuilder`, `Behaviour::ReadModel`, `ReadModelInterpreter`,
`TenantScope`, `SqlQueryBuilder`, the SQLite `query_read_model`, the fuzz properties,
`rust/src/kernel/read_model.rs`, `rust/project/read_models.rb`, ADRs 0025, 0026, 0041,
0050, 0052, 0054b, 0055, and every read model in `examples/` and the framework
bluebooks. Run: one scratch example (not committed) confirming the `group_by` row
drop on the in-memory adapter; a Ruby one-liner confirming the `Array#sum` versus
`inject` float difference. Not run: the Rust side of the drop (read from
`nest`, not executed), any adapter other than Memory, and Postgres collation.
