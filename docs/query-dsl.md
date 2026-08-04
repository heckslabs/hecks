> The consumer guide for queries now lives at [guides/queries-and-read-models.md](guides/queries-and-read-models.md); this file remains the original design record.

# The query DSL: what exists, and what might extend it

**Status: mostly a record of what's already built, verified directly — plus a short,
explicitly-marked list of proposed additions that are not implemented.** Grew out of
the Rails integration design doc's reasoning about associations and batch reads; kept
separate because this is a language/persistence-layer concern, not a driving-adapter
one.

## What already exists, verified

`query` and `read_model` are two separate, sibling constructs, both built on the same
shared option vocabulary (`QuerySpecification::Common::DSL`):

```ruby
where(field: value)                  # comparators: eq, ne, gt, gte, lt, lte, in, contains
order_by(field, direction = :asc)
limit(value)
offset(value)
cursor(value)
consistency(mode, timeout: nil)
freshness(mode, max_age: nil)
authorize(policy, tenant: nil)
nulls(mode)
inspect_query(mode = :sql)
use_index(name)
```

`read_model` (`ReadModelBuilder`) additionally has `reference_to`/`include` — a real,
already-built answer to "through relationships, like SQL." This was gotten wrong
once in this project's own reasoning before being checked directly: plain `query`
never crosses an aggregate boundary, but `read_model` does, and it's not dormant
scaffolding — there's a live consumer (`adapters/driven/sqlite/projection.rb`) and
real corpus usage:

```ruby
read_model "CustomerPortfolio" do
  reference_to Customer
  include Customer
  include Account
  include ATMCard
  include Transfer
end

read_model "ComplianceDashboard" do
  reference_to Account
  include Account
  include CardPayment
end
```

`include`'s cardinality (one record vs. a collection) is inferred automatically —
`many: target != @reference_target` — the root is singular, everything else is a
collection. Note separately: `ReadModel::Specification#joins` is a *different*,
unrelated field on a different class, with zero DSL method that populates it and zero
adapter that reads it — genuinely dormant, unlike `reference_to`/`include`, which are
both live. Don't confuse the two when reading the code.

## One thing left unverified, not fabricated

Whether `include`'s behavior on an absent match reads like an inner join (row dropped)
or a left join (row kept, empty collection) was not traced through
`sqlite/projection.rb` here. Worth confirming directly before relying on it for a case
where a zero-match include must not silently drop the root record — e.g. a compliance
dashboard for accounts with *no* disputed payments should very plausibly still list
the account.

## Proposed additions — not implemented, listed in rough order of how well-motivated each is

- **Aggregation** (`count`/`sum`/`avg`/`min`/`max`, with `group_by`). The sharpest gap,
  motivated by the corpus's own existing shape rather than speculation —
  `ComplianceDashboard` reads like exactly the kind of read model that wants "total
  disputed amount" or "count of open disputes," and nothing in the current vocabulary
  computes anything; every option filters, sorts, paginates, or composes raw rows.
- **`having`**, pairing directly with aggregation — filtering on a computed value is a
  different operation from `where` (which filters before any computation), for the
  same reason SQL keeps the two separate.
- **`distinct`** — a plain, common primitive with no equivalent in `comparators.rb` or
  `Options`.
- **Explicit control over `include`'s optionality**, named rather than inferred. This
  is the same problem as the unverified inner-vs-left question above, seen from the
  DSL-authoring side: right now there's no lever to say "this include is required,
  drop the row if absent" versus "this include is optional, keep the row with an
  empty collection" — `many:` only ever answers cardinality, never optionality.
  Adding the lever would resolve the ambiguity rather than leave it to be discovered
  by whatever the adapter happens to do.
- **Era/time-aware reads — "as of."** More speculative than the others, and not
  checked against the existing era/lineage system (`EraGuard`, the translation arc) —
  this may already exist there under a different name. Worth naming because it's
  unusually well-motivated for this specific project: `consistency`/`freshness`
  already govern time-related read semantics without touching *which era's shape* to
  read against, and a project this invested in versioned, historically-honest domain
  shapes is exactly where "as of era N" would earn its place if it isn't already
  solved elsewhere.
