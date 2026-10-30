# Eras live in hecks-eras and load through a capability hook

**Status:** Proposed.
Date: 2026-10-29.
Relates to: 0136 (the PostgresEra binding), 0160 (eras as a capability), 0161 (adapter registry).

## Context

The era layer is generic, but it sits inside hecks. Its boot gate (`era_check`) and the
`PostgresEra` binding are in core. Only `PostgresEra` provides lineage (`lineage_capable? = true`).
Other persistence adapters cannot have eras, so the only way to add eras to Sqlite or D1 is to
copy Postgres's lineage code.

ADR 0160 names the separation: the era logic is shared, and each adapter supplies a dialect. This
ADR decides where those pieces live.

## Decision

1. **The era logic lives in `hecks-eras`.** That covers lineage, minting, head derivation,
   translation, fork and merge, and the era gate's checks. `hecks-eras` depends on core. Core does
   not depend on it.
2. **The dialect interface lives in `hecks-eras`.** It is the set of operations an era needs from a
   database: journal and head DDL, head writes, transform expressions. An adapter that provides
   lineage implements it. Adapters depend on `hecks-eras` for that interface.
3. **Core knows capability names and hooks, not eras.** `AdapterRegistry` records `lineage`. When a
   domain binds an adapter that provides a capability, boot calls the hook registered for that
   capability. `hecks-eras` registers the `lineage` hook. Core does not know what the hook does.
4. **Boot refuses when the gem is missing.** If a bound adapter provides `lineage` and no `lineage`
   hook is registered, boot stops and names `hecks-eras` as the gem to install.
5. **Dependency direction:** `hecks-eras` → core. Adapter packages → core and `hecks-eras`. Core →
   neither at load time. There is no cycle.

## Consequences

- Sqlite, D1 and Postgres can each provide lineage by implementing the dialect. Adapters that do
  not provide lineage do not depend on `hecks-eras` at runtime.
- `era_check` and the `PostgresEra` special cases move out of core. Until they do, core keeps them.
- The Postgres lineage SQL moves with the Postgres adapter into `hecks-sql`, and `hecks-eras`
  holds no SQL.

## Not decided here

- Whether `hecks-eras` is a private or public repository.
- The exact hook signature. It is drafted when the first code moves.
- Whether D1 provides lineage. D1 reuses Sqlite's codec, so a Sqlite dialect would cover it.
