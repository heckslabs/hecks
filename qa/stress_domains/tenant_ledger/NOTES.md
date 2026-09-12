# `TenantLedger` — retention note

**Targets ANGLE-8**: `lib/hecks/fuzzing/properties/guards.rb:57-93`
(`authorize_scopes_or_refuses`) enforces `TenantScope.apply`'s tenant
boundary, and that boundary exists ONLY for queries/read models —
`authorize policy, tenant: field` is a word `QuerySpecification::
Common::DSL#authorize_impl` grants to `QueryBuilder`/`ReadModelBuilder`
alone; `CommandBuilder` never includes that module, so **no bluebook
can declare `authorize`/`tenant:` on a command at all** (confirmed by
reading the grammar directly). A write that carries a `reference_to`
from one tenant-scoped record into another's is checked by NOTHING at
dispatch time. `examples/banking/bluebook/safe_deposit_boxes.
bluebook:261` (`authorize :vault_access, tenant: :branch_code`) was the
ONLY `tenant:` declaration anywhere in the corpus before this domain —
a single data point, on the read side only, and `spec/tenant_isolation_
fuzz_spec.rb` fuzzes a completely different mechanism (Postgres-level
RLS tenant isolation across live worlds/environments, not this
bluebook-level construct at all).

## What this domain builds

Two independently tenant-scoped aggregates (`Ledger`/`Transfer`, each
with its own `region` field and a `ByRegion` query declaring `authorize
…, tenant: :region`), a cross-tenant `reference_to Ledger` on `Transfer`,
an entity (`Ledger::Entry`, with its own `Annotate` command), and a
process manager (`SettleAcrossRegions`) whose one saga leg dispatches
`Ledger::Credit` against whichever ledger `Transfer.Request` named —
crossing tenants whenever the caller's declared `region` and the named
ledger's own `region` disagree, which nothing anywhere refuses.

## The new property: `commands_respect_tenant_scope`

Declared in `lib/hecks/fuzzing/properties/guards.rb`, beside `authorize_
scopes_or_refuses`. **The rule**: an aggregate's own declared tenant
field is whichever field one of its own queries names in `authorize
policy, tenant: :field` (the exact declaration `authorize_scopes_or_
refuses` already reads off a query, reused here to name a field on the
AGGREGATE that stores the tenant it belongs to). For every stored
record (`history[:instances]` — a refused dispatch never writes one, so
"a refusal is correct behaviour, not a finding" holds by construction),
walk every `reference_to`-typed attribute pointing at ANOTHER aggregate
that also declares a tenant field: if the referenced record's own
tenant value disagrees with the referencing record's own tenant value,
the write crossed a tenant boundary and nothing refused it — a finding.
A dangling/unresolvable reference is skipped (a different property's
claim). Comparison goes through `Ports::Query::InMemory.comparable`
(the same normalization `authorize_scopes_or_refuses` already applies)
rather than `Runtime::Value#==` directly, because two independently
tenant-scoped aggregates can never share one value-object type for
their own tenant field (a value object is always declared inside the
aggregate that owns it — no corpus precedent for sharing one across an
aggregate boundary), so `LedgerRegion`/`TransferRegion` compare UNEQUAL
under `Value#==`'s own `type_name` check despite meaning the identical
tenant.

Verified both directions directly (see `spec/fuzzing/tenant_ledger_
property_spec.rb`): fires on a `Transfer` referencing a `Ledger` in a
different region, passes on one referencing a same-region `Ledger`, and
produces **zero** false positives run against 15 seeds each of
`examples/pizzas`, `examples/banking`, `qa/stress_domains/nested_pieces`,
`qa/stress_domains/waybill`, and `qa/stress_domains/ledger_ordering` —
none of which declare a second tenant-scoped aggregate for it to have
an opinion about. Run against `qa/stress_domains/tenant_ledger` itself
across 40 generated seeds, it is the ONLY property (of the whole
standard battery) that ever fires — every other declared property holds
clean on this domain — confirming the domain's only real defect is
exactly the one gap ANGLE-8 named, not an authoring mistake.

## First-run differential result (Ruby vs. compiled Rust)

`bin/project_rust qa/stress_domains/tenant_ledger`, then `cd rust &&
cargo build --no-default-features --features tenant_ledger`, then
`SEEDS=10` and `SEEDS=40` `bin/rust_conformance_fuzz qa/stress_domains/
tenant_ledger native` — **both stop at seed 1** (deterministic, not
seed-count-dependent). A hand-written script covering all 40 seeds'
full refusal lists (not just "first divergence," the way `bin/rust_
conformance_fuzz` itself reports) found exactly 5 distinct divergence
shapes:

1. **`Ledger.ByRegion` / `Transfer.ByRegion` — 78 / 72 occurrences across
   40 seeds, first at seed 1 step 2/3.** Ruby refuses `Unauthorized`
   ("ByRegion declares authorize with tenant: region — pass region: to
   name which region this ask is scoped to"); Rust refuses `TypeMismatch`
   ("named/declared query … is not generated for this domain …").
   **Not a runtime behavioral divergence — a codegen gap, and a more
   specific one than it first looks.** `rust/project/queries.rb` DID
   port `authorize`/`tenant:` for real (Phase 10, equivalence-gap plan —
   `declared_authorization_skip_reason`/`emit_query_authorization`, a
   synthetic `field == args[tenant]` condition baked into the generated
   `filter_entries` call). The actual cause, read directly off `query_
   skip_reason`: it checks `Array(query[:wheres]).empty?` and returns
   `"declares no where clauses at all"` UNCONDITIONALLY, before ever
   reaching `declared_authorization_skip_reason` — so a query that
   declares `authorize`/`tenant:` and NOTHING ELSE (no `where` at all,
   the shape both `Ledger.ByRegion` and `Transfer.ByRegion` happen to
   have) is skipped for the wrong-sounding reason, even though the
   authorization support it would otherwise reach is real. `SafeDeposit
   Box.Rented` (`examples/banking/bluebook/safe_deposit_boxes.
   bluebook:255-262`) — the only other corpus site declaring `authorize`
   — ALSO declares `where(status: "rented")`, so it clears this gate and
   was never in a position to surface this specific ordering issue. This
   is the SAME structural-refusal family `spec/support/rust_conformance_
   helpers.rb`'s own `structural_refusal_gap?`/`STRUCTURAL_REFUSAL_
   MARKER` mechanism already exists to filter out of the gated RSpec
   differential suite (ANGLE-7's own premise), just triggered by a
   narrower, previously-unexercised combination: `authorize` with no
   other `where`.
2. **`Transfer.Request` / `Ledger.Credit` on a huge `amount_cents` —
   8 occurrences, first at seed 3 step 7 (`Transfer.Request`) and seed 6
   step 4 (`Ledger.Credit`).** Both sides refuse `TypeMismatch`, but with
   different WORDING: Ruby's arbitrary-precision integers report the
   exact overflow value (`"must fit in a 64-bit integer, got
   1267650600228229401496703205376"`); Rust's `f64`-backed JSON parser
   has already lost precision by the time it reports the SAME refusal
   (`"expects Integer, got 1267650600228229400000000000000"`). This is
   the exact, already-documented `Json::Num`/f64 precision-loss class
   `rust_conformance_helpers.rb` names in its own header (`1.27e30`
   example) — not new, just the first time it fires on this domain's own
   `Integer`-typed value objects (`LedgerAmountCents`/
   `TransferAmountCents`).
3. **`Ledger.Credit` on a duplicate `Entry` — 1 occurrence, seed 5 step
   2.** Both sides correctly refuse `AlreadyExists`, but Ruby's message
   names the bare scalar (`sequence.value "echo charlie"`) while Rust's
   names the Debug-formatted wrapper struct (`sequence.value
   EntrySequence { value: "echo charlie" }`). A genuine, if cosmetic,
   Rust-side formatting difference in the `AlreadyExists` message for a
   value-object-typed entity identity field — not chased further here
   per this task's own scope (record, don't fix).

**Not logged as a Bug or fixed here** — per this stress domain's own
scope, a runtime/codegen divergence found by a stress domain is a
separate Bug/PR the orchestrator dispatches, not something authored
inside the domain's own PR. Item 1 in particular looks like the
highest-value follow-up, and a narrow one: `query_skip_reason` (`rust/
project/queries.rb`) would need to stop returning its `wheres.empty?`
reason for a query that declares `authorize`/`tenant:` with no other
`where` — the authorization support it would then reach is already real
(Phase 10) and would generate correctly, closing an entire construct
shape (any tenant-scoped query with no additional filter) rather than
just this domain's own two queries.

## Not done here, on purpose

`model_check` (`bin/model_check qa/stress_domains/tenant_ledger`)
reports clean — 2 chapters, no dead states, no unreachable protocol
steps — so no `ALLOWED_FINDINGS` entry was needed, matching `waybill`'s/
`ledger_ordering`'s own precedent of leaving that allowlist untouched
for a domain outside `MODEL_CHECK_CORPUS`. `spec/rust_conformance_fuzz_
spec.rb`'s own `DOMAINS` list is PR-2's own file to touch (ANGLE-3), not
touched here.
