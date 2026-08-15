# Postgres adapter split: plain `Postgres` + `PostgresEra` — implementation plan

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
   `where`/`order_by` IR on the aggregate's own queries. No bluebook author ever opts in explicitly
   — matches every other self-healing schema move this adapter already makes
   (`ensure_head_snapshot!`, `ensure_first_head!`).
4. **Backward-compatible naming.** `PostgresEra` keeps today's `Postgres` behavior byte-for-byte
   under a new name. Every existing consumer is explicitly repointed at it — nothing changes
   meaning silently under a domain that didn't ask for a change.
5. **Migration always goes through `all()` + `save()`, never raw `entries`/journal replay.** The
   only place era-translation has already resolved old-shaped rows into the aggregate's current
   shape is the reduced read side (`all()`/`head_view`), not the raw write history. This is the one
   mechanism for: Postgres→Sqlite, Sqlite→Postgres, and a domain later upgrading from plain
   `Postgres` to `PostgresEra` — not three separate migration stories.

## Scope

### 1. Rename `Postgres` → `PostgresEra`
- `lib/hecksagain/adapters/driven/postgres.rb` → `postgres_era.rb` (`class Postgres` → `class PostgresEra`)
- `lib/hecksagain/adapters/driven/postgres.adapter` → `postgres_era.adapter` (`Hecks.adapter "Postgres"` → `"PostgresEra"`)
- Repoint every existing consumer: `pizzas.hecksagon`, `compliance.hecksagon`, and the three specs
  named above, to `persisted_by("PostgresEra")`.
- No data migration needed for any of them (per the verified-consumer check above) — this is a pure
  rename for every domain that exists today.

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
