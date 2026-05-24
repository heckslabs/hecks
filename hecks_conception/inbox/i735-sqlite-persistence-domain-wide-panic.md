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
