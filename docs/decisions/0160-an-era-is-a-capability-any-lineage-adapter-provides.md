# An era is a capability any lineage adapter provides

**Status:** Proposed.
Date: 2026-10-29.
Relates to: 0136 (the PostgresEra binding), 0159 (the sentence reader's contract).

## Context

`PostgresEra` is an adapter and the era layer at once. Its class holds the journal, the head
derivation, minting, lineage (fork and merge), translation, and the Postgres SQL that does them.
That makes eras depend on one adapter, which is the coupling this ADR removes.

The coupling, as it stands:

- `lib/hecks/ports/persistence/plugins/era/era_check.rb` decides whether an adapter is
  lineage-capable by its class name. Its own comment says "Postgres alone answers true today".
- `era_guard.rb` calls `PostgresEra::LineageManager::CoverageCheck` by name.
- `translation/rule_compiler.rb` reads its SQL forms from the grammar under `"postgres"`, and
  `translation/expression_sql.rb` emits jsonb expressions. The compiler is generic in name only.
- `lib/hecks/projections/deploy/templates/*/mint_era_*.tmpl` mint eras through the Postgres
  adapter.
- 84 files outside `postgres_era/` reference `PostgresEra` or `postgres_era`.

The generic parts already live in `plugins/era/`, which mentions Postgres in five files, all in
comments or the SQL forms above.

## Decision

1. **An era is a capability, not an adapter.** An adapter declares that it provides `lineage`:
   a journal per domain, heads derived by era, minting, fork and merge. The era logic (lineage
   manager, mint, translation scheduling, the era gate, the shape diff) belongs to
   `plugins/era/` and is shared by every adapter that provides lineage.
2. **Each lineage adapter supplies a dialect.** The dialect holds the SQL the generic logic
   needs: journal and head DDL, head writes, and the transform expressions. Postgres's dialect
   moves with the Postgres adapter. A second dialect is a separate change.
3. **The gate asks the capability, not the class name.** `era_check` asks the bound adapter
   whether it provides `lineage`. No code compares an adapter's name.
4. **Rule forms are keyed by dialect.** `rule_compiler` reads the forms for the bound adapter's
   dialect from the grammar ledger. Rules that a dialect cannot express are refused at compile
   time, naming the dialect.
5. **`PostgresEra` stays as the binding name.** `persisted_by "PostgresEra"` keeps working. It
   resolves to the Postgres adapter with its lineage dialect, so the push train and every
   existing world are unchanged.

## Consequences

- Eras are no longer tied to Postgres in code, so a second adapter can provide them without
  touching the era logic.
- The Postgres dialect is the only dialect in this change. Nothing else gains eras yet.
- The move of the SQL adapters to `hecks-sql` takes the Postgres dialect with it. The generic era
  logic stays in hecks.
- The deploy templates mint through the capability, not the adapter name.

## Not decided here

- Whether SQLite gets a lineage dialect (JSON1 functions instead of jsonb) and when.
- Whether D1 gets one. D1 reuses SQLite's codec, so a SQLite dialect would cover it.
- The exact capability interface. It is drafted when the first code moves.
