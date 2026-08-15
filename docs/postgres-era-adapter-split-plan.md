# Postgres adapter split: plain `Postgres` + `PostgresEra` — implementation plan

**Status: implemented, on branch `postgres-era-adapter-split`** (worktree
`.claude/worktrees/postgres-era-adapter-split`, 6 commits: rename → spec-suite repoint + this doc's
own ordering rewrite → Track B → Track A → Track C → Phase 3 fixes). `bundle exec rspec`: 1577
examples, 0 failures. `bundle exec rspec --tag io`: every remaining failure traces to pre-existing
repo debt confirmed present on the branch's own base commit (`d7394fdc`) — most of
`postgres_era/lineage_spec.rb` and `domain_rename_spec.rb` blocked by an unrelated `identified_by`
block-form removal in their own fixtures, 4 `postgres_era_spec.rb` examples blocked by an unrelated
`belongs_to` removal, `saga_durability_postgres_spec.rb` blocked by an unrelated role/Governance-
framework mismatch in its own fixture, and a pre-existing `ROOT` constant collision between two
unrelated spec files — none caused by or fixed by this work, each individually reproduced against a
clean `d7394fdc` checkout to confirm rather than assumed. Not yet done: merging the branch itself,
and re-running Phase 2's real-Postgres validation spec (and the rest of the io-tagged suite) in CI
once merged.

Trigger: today's single `Postgres` adapter (`lib/hecksagain/adapters/driven/postgres.rb`) always
carries full era/lineage machinery — `hecks_eras`, advisory-lock-guarded `append`, `head_view`
compiled as a `DISTINCT ON`/`UNION ALL` reduction once a domain mints a second era — whether or
not a domain ever uses it. **Verified against every real consumer in this checkout**: `Pizzas::Order`
(`examples/pizzas/bluebook/pizzas.hecksagon`), `Compliance::AccountFreezeReview`/`BoxSurrenderReview`
(`examples/compliance/bluebook/compliance.hecksagon`), and the three specs that bind Postgres
directly (`spec/runtime/saga_durability_postgres_spec.rb`, `spec/runtime/domain_refusal_spec.rb`,
`spec/dsl_spec.rb`) — none has ever minted a second era. Everyone pays the cost; nobody uses the
capability.

Separately: once a domain *does* mint a second era, a declared query's `where` clause can never be
pushed through `head_view`'s reduction — a real SQL-semantics limit (filtering a non-partition-key
column can't be pushed through a `DISTINCT ON`/dedup step without risking a stale row winning), not
a missing index. Checked rather than assumed: neither `pg_ivm` nor SQL Server's indexed views can
auto-maintain this shape either — both explicitly forbid `UNION`/`DISTINCT` in exactly the query
class this is. See "Explicitly deferred" below for the full database survey this came out of.

This plan does three things: splits the adapter so the common case (never evolves) stops paying
for lineage it doesn't use, gives the era-evolving case a real way to get indexed reads back, and
makes an existing blocking backfill path non-blocking per a newly-adopted standing rule.

## Governing principles (settled, apply uniformly — do not relitigate)

1. **We never block.** No operation introduced or touched by this plan may hold a lock across a
   scan whose duration scales with table size. This reaches backward as well as forward — the
   *existing* `backfill_head_snapshot!` (today one blocking transaction) gets the same chunked,
   lock-free treatment as everything new here, not a pass because it predates the rule.
2. **The era workaround is Postgres-only.** The flat cache-table + two-phase-query mechanism lives
   entirely inside `PostgresEra`'s own adapter code. `SqlQueryBuilder` (shared with `Sqlite`/`D1`)
   is not touched by it — those dialect hooks (`execute_query`, `plain_column`, `from_relation`)
   are already adapter-owned, so this doesn't require reaching into shared infrastructure.
3. **Automatic derivation, not a new DSL keyword.** Which fields get indexed (cache tables for
   `PostgresEra`, plain indexes for `Postgres`/`Sqlite`/`D1`) is derived from existing declared
   `where`/`order_by` IR on the aggregate's own queries (`Aggregate#queries`, plus each entity's own
   `queries` — `query_surfaces` in `dsl/aggregate_builder.rb` walks both). No bluebook author ever
   opts in explicitly — matches every other self-healing schema move this adapter already makes
   (`ensure_head_snapshot!`, `ensure_first_head!`).
4. **Backward-compatible naming.** `PostgresEra` keeps today's `Postgres` behavior byte-for-byte
   under a new name. Every existing consumer is explicitly repointed at it — nothing changes
   meaning silently under a domain that didn't ask for a change.
5. **Migration always goes through `all()` + `save()`, never raw `entries`/journal replay.** The
   only place era-translation has already resolved old-shaped rows into the aggregate's current
   shape is the reduced read side (`all()`/`head_view`), not the raw write history. This is the one
   mechanism for: Postgres→Sqlite, Sqlite→Postgres, and a domain later upgrading from plain
   `Postgres` to `PostgresEra` — not three separate migration stories.
6. **New backfill/cache-table code picks lock keys disjoint from the four families already in use**
   — `hecks_ordinal:`, `hecks_eras:`, `hecks_head_snapshot:` (see `postgres_era/lineage/*.rb`, all
   `pg_advisory_xact_lock(hashtext(...))`). A natural new prefix is `hecks_field_cache:`; whatever is
   chosen, grep the full lock-key inventory before picking it.

## Implementation ordering

The original version of this doc listed five scope items with no stated dependency graph. Turning
it into an actual work plan surfaced a real one — Scope 1 (the rename) is a hard prerequisite for
everything else (it frees the plain `Postgres` name), Scope 5 (validation) is a hard dependent of
Scope 3 (nothing to validate until the cache-table engine exists), and Scopes 2/3/4 touch disjoint
files once Scope 1 lands, so they parallelize cleanly. It also surfaced work the original scope list
didn't name at all: the adapter's own 2700-line spec suite (`postgres_spec.rb`, 525 lines;
`postgres/lineage_spec.rb`, 1413 lines; `postgres/domain_rename_spec.rb`, 338 lines;
`adapters/query_agreement_spec.rb`, 430 lines) all bind `Hecksagain::Adapters::Postgres` directly and
need the same rename Scope 1 gives every other consumer — not mentioned in the original Scope 1, but
the same prerequisite.

```
Phase 0 — Rename (sequential, blocking, no parallelism possible)
  │  Frees the bare "Postgres" name. Nothing in Phase 1 can start before this lands —
  │  Track A creates a NEW lib/.../postgres.rb and a NEW spec/.../postgres_spec.rb at
  │  paths this phase must vacate first.
  │
  ├─ lib/hecksagain/adapters/driven/postgres.rb        → postgres_era.rb (class → PostgresEra)
  ├─ lib/hecksagain/adapters/driven/postgres.adapter    → postgres_era.adapter
  ├─ lib/hecksagain/adapters/driven/postgres/           → postgres_era/  (lineage + lineage_manager)
  ├─ driven.rb's require_relative repointed
  ├─ every real consumer repointed to persisted_by("PostgresEra"): pizzas/compliance
  │  .hecksagon + .world, saga_durability_postgres_spec.rb's inline Wire fixture,
  │  spec_helper.rb's adapter-path constant + its 4 call sites, comments in
  │  domain_refusal_spec.rb/dsl_spec.rb
  ├─ the adapter's OWN spec suite renamed + repointed (not in the original scope list):
  │    spec/adapters/driven/postgres_spec.rb           → postgres_era_spec.rb
  │    spec/adapters/driven/postgres/                  → postgres_era/  (lineage_spec.rb,
  │                                                        domain_rename_spec.rb)
  │    spec/adapters/query_agreement_spec.rb            (Postgres → PostgresEra refs updated
  │                                                        in place; stays this filename —
  │                                                        Track A adds a 5th engine to it later)
  └─ docs (README, guides) + live Rust-side comments (lineage_pass.rs, auth.rs, journal.rs,
     lex.rs) swept for accuracy; historical audit logs / dated correction entries in
     HECKS_IMPLEMENTATION_PLAN.md deliberately left untouched (point-in-time records)

  STATUS: done. Verified: `require "hecksagain"` loads clean; PostgresEra resolves and
  answers lineage_capable? true.

Phase 1 — three independent tracks, parallel (disjoint files once Phase 0 lands)
  STATUS: done, all three tracks. Track A: 24 + 23 examples (its own spec + the extended
  query_agreement_spec.rb), 0 failures. Track B: 26 examples, 0 failures.

  ┌─ Track A: new plain `Postgres` adapter (original Scope 2) ────────────────────────┐
  │  lib/hecksagain/adapters/driven/postgres.rb (NEW), postgres.adapter (NEW),         │
  │  postgres/codec.rb (NEW — real typed columns for scalars, jsonb for nested/list,   │
  │  ported from Sqlite::Codec's shape, not its SQLite-JSON-text mechanics),           │
  │  postgres/schema_builder.rb (NEW — plain CREATE INDEX per declared where/order_by  │
  │  field, both safe to index directly here since there's no reduction to route       │
  │  around), driven.rb gets its second require_relative added back,                   │
  │  spec/adapters/driven/postgres_spec.rb (NEW, modeled on sqlite_spec.rb),           │
  │  query_agreement_spec.rb gains a 5th engine (plain Postgres, alongside Memory/      │
  │  Sqlite/PostgresEra/D1) — depends on this track's own adapter existing, so it's     │
  │  the last step within this track, not a separate one.                              │
  └──────────────────────────────────────────────────────────────────────────────────┘

  ┌─ Track B: Sqlite/D1 automatic indexing (original Scope 4) ────────────────────────┐
  │  sqlite/schema_builder.rb: plain CREATE INDEX for scalar where/order_by columns;   │
  │  for value-object/list-typed attributes (JSON-encoded text per sqlite/codec.rb),   │
  │  an EXPRESSION index matching nested_expression/plain_column's own json_extract    │
  │  phrasing (an index on the raw column indexes the whole blob, not the field; a     │
  │  mismatched expression index is invisible to the planner). D1 inherits for free    │
  │  (shares SchemaBuilder with Sqlite verbatim) — no D1-specific work.                │
  └──────────────────────────────────────────────────────────────────────────────────┘

  ┌─ Track C: PostgresEra cache tables + resumable backfill (original Scope 3) ───────┐
  │  HIGHEST RISK, LEAST PARALLELIZABLE — real concurrency correctness (locking,       │
  │  crash-resumability), not mechanical refactoring. Built as one coherent piece, not │
  │  split further:                                                                    │
  │   - one narrow cache table per where-field (id PK, ordinal, value), upserted       │
  │     transactionally inside the existing append, same ordinal-guard idiom           │
  │     head_snapshot's own upsert already uses                                        │
  │   - two-phase query execution: SELECT id FROM <field>_cache WHERE value = $1, then │
  │     SELECT id, state FROM head_view WHERE id = ANY($ids) — safe through the        │
  │     DISTINCT ON reduction because id is its own partition key                      │
  │   - order_by-only queries need no cache table (sorting reduced output was never    │
  │     blocked by the reduction — only filtering was)                                 │
  │   - backfill for a query declared later against existing history: chunked by id    │
  │     range, no shared lock with append's own ordinal lock, ordinal-guarded so a     │
  │     concurrent live write always wins, resumable across a crash/second concurrent  │
  │     boot mid-backfill                                                              │
  │   - retrofit backfill_head_snapshot! itself (era 1's existing one-shot blocking    │
  │     backfill, full contents in head_compiler.rb) to the same chunked, lock-free,   │
  │     resumable shape — principle 1 reaching backward                                │
  │   - additive (aggregate_id, ordinal DESC) index on the snapshot/matview tables     │
  └──────────────────────────────────────────────────────────────────────────────────┘
  Track C STATUS: done. Two real bugs found and fixed via actual Postgres runs, not caught by
  `ruby -c`: `PG::Result#[]` raises `IndexError` (not nil) on an out-of-range index, and does
  not support negative indices the way a plain Ruby Array does — both `backfill_progress`'s
  "no row yet" check and the per-chunk "last row" cursor read needed the explicit
  `ntuples`-checked form.

Phase 2 — Validation (original Scope 5), depends on Phase 1 Track C only
  New spec in hecksagain's own suite, against a real throwaway Postgres database (never the
  dev database, PostgresProbe/before(:all)-scratch-db pattern every other real-Postgres spec
  already uses) — with a toy aggregate pushed through a real era mint. Must prove: cache-table
  correctness both before and after a mint, backfill resumability under a simulated
  crash/restart, and genuine non-blocking-ness (a concurrent write succeeding while a backfill
  is mid-scan). Not routed through Payments (~/Projects/junkdrawer/payments) — that project
  stays on Heki by its own explicit design; this is a framework capability, proven against a
  purpose-built aggregate.
  STATUS: done — spec/adapters/driven/postgres_era/field_cache_spec.rb, 7 examples, 0
  failures, all four required proofs covered (pre-mint correctness, post-mint correctness,
  crash-simulated resumability via a stubbed mid-backfill raise, and a measured concurrent
  write completing in <1s against a deliberately slowed backfill on a separate connection).

Phase 3 — Full-suite verification, depends on everything
  `bundle exec rspec` (unconditional suite) + `CI=true bundle exec rspec` or
  `--tag io` (the real-Postgres-gated suite, including the new Phase 2 spec and the extended
  query_agreement_spec.rb) run clean against local Postgres. Update this doc's own status.
  STATUS: done. Surfaced and fixed two real issues neither Phase 1 nor Phase 2 caught alone:
  a straggler `"Postgres"` string literal in exporter_spec.rb that Phase 0's rename missed
  (needed to become `"PostgresEra"`), and two top-level-constant collisions across spec files
  (`V1_SOURCE`/`V2_SOURCE` between the new field_cache_spec.rb and the pre-existing
  lineage_spec.rb, `SPEC_DB` between the new postgres_spec.rb and the pre-existing
  postgres_era_spec.rb) — not a lint nitpick: RSpec loads every spec file into one process, so
  the second same-named constant silently keeps the first's VALUE, meaning field_cache_spec's
  own mint test was silently running against lineage_spec's bluebook content whenever the full
  suite ran together. `bundle exec rspec`: 1577 examples, 0 failures.
```

Tracks A and B were delegated to parallel subagents once Phase 0 landed; Track C (and Phase 2) were
built directly rather than delegated — the risk in Track C is real concurrency correctness under
crash/restart, not mechanical translation of an existing pattern, and that class of bug is exactly
the kind a subagent's own tests won't reliably catch without close, incremental supervision.

## Scope (unchanged in substance from the original version — ordering now lives above)

### 1. Rename `Postgres` → `PostgresEra`
See Phase 0 above.

### 2. New, plain `Postgres` adapter
- Flat, one table per aggregate. Real typed columns for scalar attributes, jsonb for nested/list —
  the same shape decision `Sqlite` already made for its own aggregate table.
- No `hecks_eras`, no lineage, no advisory-lock-per-write for era tracking.
- Automatic `CREATE INDEX` for every field a declared query filters or sorts on — both `where` and
  `order_by` are safe to index directly here, since there's no reduction to route around.

### 3. `PostgresEra`: flat per-field cache tables + two-phase query execution
- One narrow table per `where`-field (`id` PK, `ordinal`, `value`), upserted transactionally inside
  the existing `append`, same ordinal-guard idiom `head_snapshot`'s own upsert already uses
  (`WHERE ordinal < EXCLUDED.ordinal`).
- Query execution becomes two-phase: `SELECT id FROM <field>_cache WHERE value = $1`, then
  `SELECT id, state FROM head_view WHERE id = ANY($ids)` — safe to push through the `DISTINCT ON`
  reduction because `id` is its own partition key, unlike an arbitrary field.
- `order_by`-only queries need no cache table — sorting the final reduced output was never blocked
  by the reduction in the first place; only filtering was.
- Backfill for a query declared later against an aggregate with existing history: chunked by id
  range, no shared lock with `append`'s own ordinal lock, ordinal-guarded so a concurrent live write
  always wins over a backfill row, and resumable — a crash or a second concurrent boot mid-backfill
  has to be a handled case now that it's no longer one atomic transaction, not assumed away the way
  the current single-shot version gets to.
- Retrofit `backfill_head_snapshot!` itself (era 1's existing one-shot blocking backfill) to the
  same chunked, lock-free, resumable shape — principle 1 reaching backward, not new-code-only.
- Additive, independent of the cache-table work: an `(aggregate_id, ordinal DESC)` index on the
  snapshot/matview tables, worth having regardless once running on PG18+ for skip-scan-friendly
  reduction — speeds up every read that still has to run the reduction, doesn't change what can be
  pushed through it.

### 4. `Sqlite` / `D1`: automatic indexing, JSON-extraction-aware
- Plain `CREATE INDEX` for scalar `where`/`order_by` columns.
- For value-object/list-typed attributes (stored as JSON-encoded text in their own column per
  `sqlite/codec.rb`), the index expression must match however the shared query builder's own
  `nested_expression`/`plain_column` hooks phrase the comparison (`json_extract`-aware) — indexing
  the raw column directly indexes the whole encoded blob, not the field inside it, and the planner
  won't use a mismatched expression index.
- `D1` inherits this for free — it shares `SchemaBuilder` with `Sqlite` verbatim.

### 5. Validation
- New spec in hecksagain's own suite (`spec/`), against a real throwaway Postgres database — never
  the dev database, matching `rust/host`'s own `dispatch.rs` test precedent — with a toy aggregate
  pushed through a real era mint. Must prove: cache-table correctness both before and after a mint,
  backfill resumability under a simulated crash/restart, and genuine non-blocking-ness (a concurrent
  write succeeding while a backfill is mid-scan).
- Not routed through Payments (`~/Projects/junkdrawer/payments`) — that project stays on Heki by its
  own explicit design; this is a framework capability, proven against a purpose-built aggregate.

## Explicitly deferred, not forgotten

- **`OracleEra`.** The one database surveyed that technically clears every bar this plan checks
  against — real incremental materialized views (via materialized view logs, so no `UNION`/`DISTINCT`
  wall), genuine online partition operations, `DBMS_LOCK` with the same transaction-scoped release
  guarantee Postgres's advisory locks give. Not scheduled now. Given hecksagain's actual destination
  is enterprise deployment, not a permanently-internal tool, this is a real future adapter, not
  something to dismiss on "wrong spirit for an internal tool" grounds — revisit deliberately, don't
  let it fall out silently.
- **MySQL, CockroachDB, SQL Server** — surveyed and ruled out on checked, not assumed, grounds:
  MySQL's `ALTER TABLE ... ADD PARTITION` blocks concurrent writers (confirmed against MySQL's own
  docs and bug tracker); CockroachDB's blocking advisory locks currently ignore `lock_timeout` and
  can hang indefinitely, and `pg_try_advisory_lock` isn't implemented; SQL Server's indexed views
  explicitly forbid `UNION` and general `DISTINCT`, the same wall `pg_ivm` hits, for the same reason.
  CockroachDB's advisory-lock support is actively under development upstream — worth re-checking
  before treating this as permanent.
- **Two open gaps in the `all()` + `save()` migration mechanism**, in either direction: saga/process-
  manager state (`hecks_saga_instances`) isn't instance state and needs its own explicit
  read-and-reinsert step; the `mirrors` field carried on every `Entry` hasn't been fully traced and
  should be checked before any migration script built from this plan is trusted as complete.
