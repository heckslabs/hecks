# Project status

What works today, what is experimental or partial, and where the gaps are
written down. The current release number, the planned list and the
stability promise's one-paragraph summary stay on the
[README](../../../README.md#project-status).

[`docs/1.0-readiness.md`](../../1.0-readiness.md) states plainly what the
stability promise made at `1.0.0` covers — the DSL and runtime API in
[the DSL reference](../reference/index.md) won't change in a breaking way
without a major-version bump — and what it explicitly doesn't cover yet
(query DSL aggregation beyond `count`/`median`/`group_by`, Rust codegen for
`read_model` beyond its proven subset, Rails integration, Drivers, the
outbox's standalone relay — see that doc's "Explicitly not covered"
section). [ADR 0025](../../decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md),
the breaking DSL redesign the `1.0.0` release was blocked on, is fully
landed — the [README's quickstart](../../../README.md#quickstart) shows the
current syntax.

## Working today

Exercised in CI on every push (the whole suite, alongside
`hecks model_check` and `hecks fuzz`):

- The DSL → IR → dispatch pipeline; the Ruby reference runtime.
- Persistence adapters: Memory, Sqlite, Postgres, PostgresEra, Heki,
  Folder.
- Static model checking, property-based fuzzing (Memory, Sqlite, and
  Postgres adapters), corpus regression, golden IR snapshots.
- The generated Rust dispatch runtime, differentially tested against
  Ruby continuously (not merely at release time).
- WASM projection (WASI and browser targets) from the same generated
  Rust.
- AWS Lambda/SAM deployment projection; Mermaid diagram projection.
- Both MCP servers described in
  [AI-native development](ai-native-development.md) — the Storehouse
  dispatch door landed very recently and is the least battle-tested item
  on this list.

The first item, on the in-memory adapter, in one sitting: a declared rule
refuses a command before it runs, and the same command goes through once
the rule holds.

<!-- doctest:boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
Hecks.hecksagon("Pizzas") do
  attaches "Governance"
  Pizzas::Order.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
-->

```ruby
order = Order.create_pizza!(name: "Quattro", pizza: { price_cents: { cents: 1500 }, size: "large" })

order.purchase!(customer_name: "Sam", amount: { cents: 1500 })   # ~> GivenNotMet: a pizza needs at least one topping

order.add_topping!(topping: "Olive", amount: 2)
order.purchase!(customer_name: "Sam", amount: { cents: 1500 })
order.status   # => "sold"
```

## Experimental or partial

- Property-based fuzzing defaults to the Memory adapter but also runs
  against real Sqlite and Postgres (`hecks fuzz adapter=sqlite` or `adapter=postgres`
  — Postgres needs a real reachable local server and is noticeably
  slower per seed, so pass smaller `--seeds`/`--steps` than the default
  sweep). A reference-hop query field (`owner/field`) is *queried*, not
  just indexed, on every SQL adapter: the hop folds into a local `in:`
  clause before any adapter sees it
  (`spec/adapters/query_hop_agreement_spec.rb`).
- Query aggregation is partial. A `read_model` can declare `count`,
  `median` and `group_by`, on Ruby and on the generated Rust runtime;
  there is no `sum`, `avg`, `min` or `max`, and a plain `query` reduces
  nothing. A `group_by` leaf holds one row: when several rows share a key
  path the ask refuses, on every adapter and in Rust, rather than keeping
  the first ([ADR 0061](../../decisions/0061-query-dsl-aggregation-count-sum-group-by.md)).
- `PostgresEra`'s schema-evolution/translation system works and is
  exercised in CI; the migration/rekey data-loss findings tracked
  against it (era-migrated deletes resurrecting, rekey SQL invisible
  to the approval digest, a dotted `compute` exempting its whole
  parent attribute from the equivalence gate) are fixed and
  live-verified against real Postgres as of 2026-08-27 — see
  `docs/future-features.md`'s "Bug audits" section for the specifics
  and what's *not* independently re-checked yet. A `compute` whose
  source is a dotted member fires in the compiled SQL like any other, so
  its mint converts the record.
- Rust codegen runs a proven subset of `read_model` queries (see
  [Projections](projections.md) for its shape); one outside that subset
  is refused in Rust with a "not generated for this domain" error and
  still requires Ruby.
- The transactional outbox ([ADR 0053](../../decisions/0053-transactional-outbox-for-domain-events-and-effects.md),
  `Runtime::Outbox`): a command's save, its events, and one
  `pending` row per policy/process-manager consumer commit together on
  Sqlite/Postgres/PostgresEra (Memory keeps in-process rows); the
  dispatcher drains them inline, the next boot redrives `pending` rows
  and surfaces `claimed` ones. Heki/LocalStorage/D1 have no outbox yet
  (boot warns); the relay is the dispatching thread plus boot-time
  reconciliation, not a separate process.

## Planned, and the running list of gaps

The planned-or-research-only list lives on the
[README](../../../README.md#project-status), where
`spec/readme_planned_adrs_spec.rb` checks it.
[`docs/future-features.md`](../../future-features.md) is the project's
own running list of gaps, ranked by how much depends on them — read it
before assuming a capability exists that isn't demonstrated here.
