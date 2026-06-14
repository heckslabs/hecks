---
ref: i735
title: SQLite persistence applies domain-wide and panics on CREATE TABLE failure
status: open
category: bug
area: runtime / persistence
filed_by: miette
filed_at: 2026-05-23
severity: high (panic takes down the whole dispatch bus)
---

# i735 — SQLite persistence over-applies + panics, taking down the bus

## Symptom
Dispatching ANY command against a multi-aggregate domain where some
hecksagon declares `adapter :sqlite` panics the whole runtime:
`thread 'main' panicked at src/runtime/sqlite_repository.rs:91` —
`sqlite create <table>: <CREATE TABLE error>`. The bus is down for that
whole root.

## Discovered
`governance.hecksagon` declared `adapter :sqlite` but it was INERT for
its entire life (governance.db never existed — governance ran on heki).
When `:sqlite` became real (PR #687), that declaration activated, and
dispatching against `hecks_conception/aggregates` (which loads governance
in the combined domain) panicked. Immediate fix: governance.hecksagon →
`adapter :heki` (its actual behaviour). This card is the root fix so
`:sqlite` is safe to declare anywhere.

## Two real defects
1. **Domain-wide application.** `Runtime::apply_sqlite_persistence`
   (`rust/src/runtime/mod.rs` ~189) rebuilds EVERY aggregate in the
   combined domain on the SQL backend when ANY attached hecksagon
   declares `:sqlite`. It should scope to the DECLARING hecksagon's own
   aggregates (by context/domain), not the entire conception. (Worked
   for the isolated daily-musing demo only because that root has one
   aggregate.)
2. **Panic on CREATE TABLE failure.** `SqliteRepository::create_table`
   (`sqlite_repository.rs:90-91`) `unwrap_or_else(|e| panic!(...))`.
   A SQL-incompatible column (reserved word like `order`/`group`, an
   attribute named `id` colliding with the PK, etc.) crashes the dispatch
   path. It must degrade gracefully — skip/fall back to heki for that
   aggregate, never panic the runtime.

## Fix
- Scope `apply_sqlite_persistence` to the `:sqlite` hecksagon's aggregates.
- Make `create_table` (and construction) non-panicking; on failure, log
  and fall back to the heki/memory repo for that aggregate.
- Then governance.hecksagon can re-enable `:sqlite` (revert to the
  sqlite adapter) and validate it persists across Propose/Permit/Activate.

## RESOLVED 2026-06-14 (both defects)

**Defect 1 (scoping).** `apply_sqlite_persistence` now maps `context → db`
for every `:sqlite` hecksagon and rebuilds ONLY aggregates whose
`agg.context == hecksagon.name`. No more domain-wide over-apply. Guard :
`rust/tests/sqlite_scope_test.rs :: sqlite_scopes_to_its_declaring_context_only`.

**Defect 2 (no panic).** `SqliteRepository::new` + `create_table` are now
FALLIBLE (return `Result`, no `panic!`). Because the lazy `OnceCell` init
cannot host a fallible constructor AND the forwarded read surface
(`find`/`save`) is infallible, `Backend::Sql` became EAGER : the repo is
built at boot in `apply_sqlite_persistence`. On failure the aggregate is
REFUSED — its repository is dropped (no silent heki fallback, per Decision
1), a loud reason is recorded in `Runtime.refused_persistence` + logged,
and a dispatch returns the new `RuntimeError::PersistenceRefused` (never a
panic, never a misleading UnknownAggregate). Guard :
`a_sql_incompatible_column_refuses_the_aggregate_without_panicking`
(boot refusal + behavioral dispatch assertion).

**Bonus fix.** Eager construction surfaced a LATENT collision : every
aggregate carries an `id` attribute, which `apply_sqlite_persistence`
included in the typed columns while `create_table` always adds
`id TEXT PRIMARY KEY` → "duplicate column name: id". Sqlite was effectively
broken for ANY real aggregate (latent only because the old lazy path never
built a table in production). Fixed by excluding `id`/`created_at`/
`updated_at` from the typed columns.

**The `command_dispatch.rs` guard is GENERATED** — it lives in the snippets
`codegen/command_dispatch_shape/snippets/{phase_05_repo_borrow,sec_09_bulk_dispatch}.rs.frag`
and was regenerated (golden byte-identical). Never hand-edit the tracked
file.

**Tradeoff accepted (note for future-me).** Eager SQL means a fork-per-
dispatch boot opens the connection + loads the full table for EVERY wired
sqlite aggregate, even untouched ones — the lazy path avoided that. Nothing
is wired to `:sqlite` today so there is no live cost ; this is the price of
boot-time storage self-awareness (Decision 1). Revisit if a hot sqlite
domain ever makes per-boot eager-load-all measurable.
