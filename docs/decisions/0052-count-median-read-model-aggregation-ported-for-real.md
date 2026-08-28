# `count`/`median` read-model aggregation — ported for real, reusing existing machinery rather than a new two-head-join framework

**Status:** Shipped, with explicit user authorization. `docs/decisions/0050` (`group_by`) explicitly deferred `count`/`median` as needing "a genuinely separate, harder two-head-join framework." That framing turns out to have been wrong, found only by actually looking at the real corpus shape and Ruby's own interpreter closely: `count`/`median` need NO new join framework at all. This ADR ships both, for the real corpus's two declarations (`Banking::DisputedPaymentCount`, `Banking::DisputedPaymentMedian`).

## The framing that was wrong, and what's actually true

`DisputedPaymentCount`/`DisputedPaymentMedian` are **rooted**, not rootless: `reference_to Account`, `include Account`, `include CardPayment`, `where(status: "disputed")`, then `count`/`median :amount`. This is structurally IDENTICAL to `ComplianceDashboard` — a read model this generator has already shipped, unchanged, for a real corpus example — a single root plus one filtered many-side head, using the exact same `filtered_head`/`apply_filtered_head_options` machinery (`where`/`order_by`/`limit`/`offset` on the ONE eligible many-side head, `seal_query_options`'s own build-time guarantee). `count`/`median` are not a different SHAPE of read model; they're a different REDUCTION of the same already-filtered row set `ComplianceDashboard` already returns as an array. No second root, no join between two many-side collections, nothing resembling what "two-head-join" implies.

The one thing `count`/`median` genuinely need is deciding WHICH head to reduce, and — for `median` — reading one numeric field off each row. Both turn out to be simpler than `group_by`'s own port:

- **Which head**: `seal_aggregation` (Ruby, build time) already guarantees exactly one `many`-side head whenever `count`/`median` is declared (the same guarantee `seal_group_by` gives `group_by`). `ReadModelHead.many` (a field this kernel already carries) identifies it directly at runtime — no new `aggregation_target` field needed on `ReadModelDef` at all.
- **Reading `median`'s field**: `group_by` needed a bespoke, per-read-model GENERATED function because unwrapping an entire row's worth of attributes (recursively, through nested value objects and entities) is a type-level fact the kernel's generic interpreter has no access to once holding serialized `Json`. `median` only ever unwraps ONE declared field, and `query_comparators::comparable` — already a fully generic, RUNTIME, structural VO-unwrap (numeric-member-wins-or-sole-member-wins) — is the exact same function `where`/`order_by` already reuse for the identical purpose. No codegen-time type knowledge needed; `median` is a plain, hand-written, fully data-driven kernel function.

## What was ported

**Kernel** (`rust/src/kernel/read_model.rs`):
- `ReadModelDef.count: bool` and `ReadModelDef.median_field: Option<&'static str>` — both plain data fields, unlike `group_by`'s function pointer.
- `run()`'s output loop: for the one head where `head.many` is true, `def.count` renders `Json::Num(rows.len() as f64)`; `def.median_field` calls the new `median()` function. Both branches sit alongside the pre-existing `group_by` branch (mutually exclusive by construction — `seal_aggregation` refuses combining any of the three).
- New `median(rows, field) -> Json`: digs the field, reduces via `query_comparators::comparable`, drops nulls, sorts. An ODD count returns the middle value UNCONVERTED (preserving whichever `Json` numeric variant `comparable` produced — `Num` or `Float` — matching Ruby's own `values[middle]`); an EVEN count returns `Json::Float` ALWAYS (Ruby's own `/2.0` forces float division regardless of the operands' own types) — this exact typing distinction (`700` vs `700.0`) was verified byte-for-byte against Ruby, not assumed.
- `query_comparators::as_f64` made `pub(crate)` (was private) — reused for `median`'s own sort/average, the same `pub(crate)` treatment `to_s` already got for an analogous reuse in `group_by`'s `nest()`.

**Both generators** (`rust/project/read_models.rb`, mirrored in `rust/codegen/src/read_models.rs`):
- `count`/`median_field` added to `READ_MODEL_BARE_KEYS` (previously absent — any declaration at all fell straight into the "declares count — out of scope" refusal via the FIRST gate, before ever reaching head-eligibility logic).
- `read_model_skip_reason` gains a final `aggregation_skip_reason` check, run AFTER the ordinary where/order_by/limit/offset content check already passes for the eligible head (since both real declarations reuse that unchanged) — `count` needs no further validation; `median` confirms its own field names a real, NUMERIC attribute via `query_field_kind` (reused wholesale from `queries.rb`, the SAME "comparable reduces to a JSON number" rule the kernel's own runtime reduction relies on).
- `read_model_def`/`emit_read_model_def` extended with the two new fields; `READ_MODEL_TABLE_ROW_PLACEHOLDER` updated in the Ruby generator, the exemplar source, and the codegen crate's own constant.

## Verification

- **Functional correctness, both typing edge cases, verified independently**: a real-corpus script (3 disputed payments authorized/captured/disputed at 900¢/500¢/300¢ cents, queried at 2 disputes then again at 3) run through the native binary and compared byte-for-byte against Ruby's own `Fuzzing::Replay.call` output — exact match including the ODD/EVEN typing distinction (`3 disputes → median 700` bare Num; `2 disputes → median 700.0` Float).
- **Both generators verified in lockstep**: `spec/codegen_parity_spec.rb --tag io`, 8/8, first attempt — no whitespace surprises this time (`count`/`median` needed no multi-line generated code, unlike `group_by`'s own quirky heredoc indentation issue).
- `spec/rust_conformance_spec.rb spec/codegen_parity_spec.rb --tag io`: 30/30, including `read_models.json` (the standard fixture exercising `DisputedPaymentCount`/`DisputedPaymentMedian` through the real differential harness).
- Full sweep: `bundle exec rspec` (2232/0), `bundle exec rubocop` (645 files/0 offenses).
- Every real domain builds clean: banking, compliance, pizzas, roster, meta. `embryonaut`'s build failure confirmed pre-existing and unrelated (`git stash` reproduces it identically without any of this session's changes).
- All real corpus domains besides banking regenerate byte-identically — no unintended drift from the `count`/`median_field` field additions.
- `git status` confirmed clean of unrelated byproduct drift before commit.

## What this means for the backlog

Both of `docs/decisions/0041`'s own remaining "structurally close" items — `group_by` and now `count`/`median` — are shipped. The two-head-join framework `count`/`median` were assumed to need never had to be built; the real gap was narrower than the original scoping assumed, found only by looking directly at the real corpus declarations rather than reasoning from the read-model DSL's own full generality.
