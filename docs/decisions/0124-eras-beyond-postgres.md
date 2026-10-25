# Eras beyond Postgres

**Status:** Proposed — awaiting decision. Nothing is built. Date: 2026-10-24. Follows [0033](0033-eras-become-a-loadable-persistence-plugin.md) (eras are a persistence plugin) and [0123](0123-an-adapter-provides-capabilities-and-a-ledger-says-which-dialects-compile.md) (the translation ledger already writes down a Sqlite form for every rule kind).

## Context

An era is one storage shape of a domain. `PostgresEra` keeps every era's journal in one partitioned table and lets exactly one era be written: the write fence. The fence is Postgres row-level security. Provisioning turns on `FORCE ROW LEVEL SECURITY` on the journal, and each mint replaces one policy, `hecks_current_era`, so that an `INSERT` is accepted only when its `era` column is the current ordinal (`MintTransaction#advance_era!`). A process still running the code of an older era is refused by the database itself, whatever that code does. Boot refuses a superuser or `BYPASSRLS` role, which the policy cannot bind, unless the world opts in with `allow_superuser`.

Sqlite and D1 have nothing equivalent: no roles, no row policies, and every connection can do whatever the file allows. So a domain persisted by `SqlitePersistence` or `D1` has no eras. A shape change there is not versioned, and an older process can write the old shape into the new one. The Rust host has no Sqlite backend at all today (`BACKENDS` in `rust/host/src/ir.rs`).

What the fence must guarantee, whatever the store:

1. Only the current era's writes land. A writer that booted on an older era is refused at write time, not later by an audit.
2. The refusal comes from the store, or from one statement the store runs atomically, so no window opens between "check the era" and "write".
3. A mint moves the fence and materialises the new era's heads in one transaction.

## Options

### A. A trigger is the fence

At provisioning, create `hecks_current_era (ordinal INTEGER NOT NULL)` with one row, and a `BEFORE INSERT` trigger on the journal: `WHEN NEW.era <> (SELECT ordinal FROM hecks_current_era) BEGIN SELECT RAISE(ABORT, 'hecks: era N is not the current era'); END`. A mint updates the one row inside the same transaction that writes the era and its heads.

- Meets 1 to 3: the store refuses, and a trigger runs inside the inserting statement.
- Sqlite has triggers; D1 is Sqlite and documents `CREATE TRIGGER`, which needs checking against D1's limits before building.
- Nothing stops a connection from dropping the trigger, the same way nothing stops a Postgres superuser. The threat is a stale process, not a hostile one, and a stale process does not drop triggers. Provisioning checks the trigger is present on every boot, as `force_row_security!` checks RLS.

### B. The adapter checks before it writes

Each write opens `BEGIN IMMEDIATE`, reads the current era and refuses if it is not the process's own, then inserts.

- Sqlite serialises writers, so the check and the write cannot interleave. D1 has no interactive transactions, only batches, so this needs a statement the batch can make conditional (option C).
- The fence lives in the adapter's code, so a process running an older adapter, one written before the check, is not fenced at all. That fails guarantee 1.

### C. A conditional insert

Every journal write becomes `INSERT ... SELECT ... WHERE (SELECT ordinal FROM hecks_current_era) = :mine`, and the adapter refuses when no row was inserted.

- One statement, atomic on every SQL store, D1 batches included, and Postgres could use it too.
- Like B, it is the adapter's code that fences, so it does not stop an older binary.

### D. Eras stay Postgres-only

Keep refusing eras on Sqlite and D1, and say so in the docs: a domain that needs versioned storage binds Postgres.

- Nothing to build or maintain. Sqlite and D1 domains keep changing shape unversioned, which is the gap this ADR exists to close.

## Recommendation

Option A, with the trigger checked at every boot. It is the only option besides RLS where the store, not Hecks code, refuses the stale writer, so it keeps the guarantee PostgresEra gives. The translation side is mostly in place: the ledger (`lib/hecks/grammar/translation_rules.json`) carries a Sqlite form for every rule kind, so a `SqliteEra` compiler fills those the way `RuleCompiler` fills the Postgres ones. Option C is worth adding beside A as a second line of defence only if a store turns up that has neither row policies nor triggers.

Before building, confirm that D1 accepts the trigger and `RAISE(ABORT, ...)`, and decide whether the Rust host gets a Sqlite backend or a Sqlite-era domain stays Ruby-hosted.

## Consequences if accepted

- A new `SqliteEra` (and a D1 variant) persistence adapter, declaring `provides "set_transform"` like the other SQL adapters, with provisioning, a mint transaction and the trigger check.
- The Sqlite forms in the translation ledger become executed, so each needs an equivalence spec against the in-process rewrite, as `derive_equivalence_spec.rb` holds the Postgres forms.
- The `allow_superuser` escape hatch has no Sqlite counterpart: a Sqlite connection has no role to judge.
