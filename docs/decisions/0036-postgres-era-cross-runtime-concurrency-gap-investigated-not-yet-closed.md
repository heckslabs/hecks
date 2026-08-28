# PostgresEra's cross-runtime concurrency gap — investigated, two real implementation hazards found, not yet safely closeable in one pass

**Status:** Investigated, not implemented. This ADR documents the gap precisely and the two blockers found tracing the real code, so a future session doesn't have to re-derive them. Deliberately not shipping a code fix this round — see "Why this stayed a design doc," below.

## Context

ADR 0035 gave Ruby's plain `Postgres` adapter real optimistic concurrency (`hecks_version` + `expected_version:` + bounded `StaleWrite` retry) and explicitly, deliberately left `PostgresEra` out of scope: it falls back to `Runtime::AggregateLock`, an in-process Ruby `Mutex` keyed `[domain, aggregate, id]` (`lib/hecks/runtime/aggregate_lock.rb`), held for the whole `run_dispatch_order` (hydrate through save) by `Interpreting#run_dispatch_order_with_isolation` (`lib/hecks/runtime/interpreting.rb:59-65`). ADR 0035's own text calls this "correct... but coarser than a CAS-capable path would be" — correct because it assumed one process per bound adapter instance, same as Heki/Memory.

That assumption is false the moment `rust/host` exists. `rust/host/src/dispatch.rs` independently dispatches against the same `PostgresEra`-bound tables from a separate OS process (a Lambda), using `pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))` held for its own whole hydrate-then-append sequence (`dispatch.rs:134-135`, comment at `:73-84` explicit about why: "two concurrent Lambda invocations... could both rehydrate against the same prior steps... and both append"). Ruby's in-process `Mutex` is invisible to Postgres and to Rust's advisory lock — if the same aggregate is ever dispatched by both a Ruby process and a Rust process concurrently, there is no protection against a lost update between them at all. ADR 0035 never mentions Rust; this is the actual live gap a "Ruby and Rust behave identically" claim has to close.

## What already exists, closer than expected

`PostgresEra` is not undefended today. `append`/`atomic_put` (`lib/hecks/ports/persistence/plugins/era/postgres_era.rb:288-316`) already wrap the journal INSERT in `@db.transaction { lock_writes!; append_and_project!(entry) }`, and `lock_writes!` (`:445-450`) already takes a REAL Postgres advisory lock: `pg_advisory_xact_lock(hashtext('hecks_ordinal:' || @lineage.domain))`. This is genuinely cross-process-safe — for the moment of the write itself.

It doesn't close the race, for one precise reason: it locks only the final append, not the hydrate-then-decide sequence that precedes it. Two writers can both hydrate (no lock held yet), both compute mutations against the same prior state, and then race for `lock_writes!` one after the other — the second one still blindly appends its own stale-computed mutation, having never been told anything changed. Rust's own lock is held for that whole sequence; Ruby's isn't. Matching Rust's *scope*, not just adding a lock, is the actual fix — and that's where both blockers below come from.

## Blocker 1 — the two engines don't agree on what a domain is called

Rust's lock key uses `config.domain`, which comes from the `HECKS_DOMAIN` environment variable, which deploy tooling sets to `world.domain` — the bluebook's own declared PascalCase name (`bin/project_deploy:78-83`, its own comment: *"`world.domain` — 'Embryonaut', not the directory's lowercase 'embryonaut' — is what Ruby's own `LineageManager` actually writes into `hecks_eras.domain`... HECKS_DOMAIN has to match that string exactly, or `rust/host`'s own boot-time `era_exists` check refuses forever... caught live the first time this generator shipped it as `domain_name` [the directory basename] instead."*).

Ruby's `PostgresEra#lock_writes!` uses `@lineage.domain`, which is `@domain`, which defaults to `aggregate.storage_name` (`postgres_era.rb:153`) — `Naming.snake(@name)` on the AGGREGATE's own name (`lib/hecks/bluebook/behaviour/aggregate.rb:79`), not the chapter's. Checked every real example `.world` file with `persisted_by("PostgresEra")` (chess, pizzas, roster, compliance): none of them sets `domain:` explicitly, so all four are on the default. For a single-aggregate chapter where the aggregate happens to share the chapter's own name (Chess chapter → Chess aggregate), `Naming.snake("Chess")` = `"chess"` coincidentally looks plausible next to a PascalCase `"Chess"` — but the STRINGS themselves already differ in case (`"chess"` vs `"Chess"`), and `hashtext` is byte-sensitive: `hashtext('hecks_lambda_journal.chess')` and `hashtext('hecks_lambda_journal.Chess')` are different lock IDs. They were never going to collide.

For a genuinely multi-aggregate chapter, it's worse: `aggregate.storage_name` would differ per aggregate (`"account"`, `"customer"`, `"transfer"`, all under one `Banking` domain), while the architecture's own `hecks_journal_<domain>` is one shared table per CHAPTER, not per aggregate — meaning `@domain`'s current default may already be structurally wrong for that shape, independent of this ADR's own concerns. No real corpus example currently binds a multi-aggregate chapter to `PostgresEra` (banking uses Heki), so this hasn't been exercised or caught yet.

**This means simply changing my new lock's key to `@lineage.domain` would not have worked** — it would have looked like a fix (real Postgres advisory lock, right SQL, right place) while never actually colliding with Rust's own lock, silently leaving the exact race this ADR set out to close. Found by tracing the actual deploy-time env var derivation, not assumed.

## Blocker 2 — `PG::Connection#transaction` cannot be nested the way this fix needs

The natural-looking fix is to wrap the *whole* `run_dispatch_order` (hydrate through save) in one outer `@db.transaction` holding the lock, matching Rust's scope. It doesn't work with the `pg` gem's actual `transaction` method (`pg-1.6.3.../lib/pg/connection.rb:308-324`):

```ruby
def transaction
  rollback = false
  exec "BEGIN"
  yield(self)
rescue ...
ensure
  exec "COMMIT" unless rollback
end
```

There's no savepoint/nesting awareness at all. `append`/`atomic_put` already call `@db.transaction { ... }` internally. If dispatch is wrapped in an OUTER `@db.transaction` too, the INNER call's own `exec "BEGIN"` is a harmless no-op (Postgres warns, doesn't start a real nested transaction) — but its `ensure`'s `exec "COMMIT"` is NOT harmless: it commits (and Postgres releases the advisory lock at commit) as soon as the inner `append` call returns, regardless of whether the outer wrapper's own block has more work left. The lock would be released the moment `save` finishes, not when the outer wrapper intends — silently reopening the exact race the outer wrap was meant to close, in a way that would pass a shallow smoke test (no exception raised, lock IS taken, IS released — just at the wrong moment under real concurrent load).

Closing this needs `append`/`atomic_put` to detect they're already inside a transaction (e.g., threading a `already_in_transaction:` flag, or replacing `@db.transaction` with a `@db.exec("BEGIN") unless already_open` pattern) and skip opening + committing their own — a real, if small, change to a `private`-boundary-crossing piece of shared machinery, not a one-line fix.

## Two viable directions, neither attempted here

1. **Port real CAS into `PostgresEra`** (ADR 0035's own deferred option (a)) — needs the append path to check the aggregate's current head ordinal against what was read at hydrate time, refusing/retrying on mismatch, the same shape ADR 0035 built for plain `Postgres`'s `hecks_version`. ADR 0035's own words on why this wasn't attempted there still apply here: "extending CAS into that shape (per-era `hecks_version` semantics, interaction with `LineageManager`, view chains) is real, separate design work."
2. **Share Rust's advisory lock** (option (b), what this ADR investigated) — needs Blocker 1 (fix the domain-naming default so both engines derive the same lock-key string — likely: `PostgresEra` should default `@domain` to the owning chapter's own declared name, not `aggregate.storage_name`, with a full audit of what that changes for `hecks_journal_<domain>` naming too) and Blocker 2 (transaction-nesting) both resolved together, then a real two-process concurrent test (mirroring `spec/adapters/driven/postgres_concurrent_dispatch_spec.rb`'s own pattern) proving neither engine can silently overwrite the other's write.

## Why this stayed a design doc, not a commit

Both blockers were found by reading the real code, not assumed — but neither could be verified end-to-end in this environment: `rust/host` doesn't build here (rustc 1.94.0 installed, `wasmtime`/`aws-config` need ≥1.94.1 — tracked separately as the toolchain-pin item). Shipping a code change that *looks* like it closes the most serious gap in this whole audit, without being able to run it against a real `rust/host` binary and prove the lock keys actually collide, would be worse than shipping nothing — it would read as fixed when it isn't, exactly the kind of false confidence this whole audit started by rejecting. This gets implemented and proven once the toolchain (Phase 9) is in place to build and run `rust/host` for real.

**UPDATE (Phase 9, same session)**: the toolchain blocker described above is closed — `rust-toolchain.toml` now pins rustc 1.98.0, `rust/host` builds clean, and `spec/rust_host_lineage_conformance_spec.rb`'s full suite (including the real-Postgres, RLS-fenced-app-role case) runs and passes for real, confirmed directly this session. **This ADR's own two blockers (the domain-naming mismatch, the transaction-nesting hazard) are NOT touched by that fix and remain fully open** — Phase 9's scope was strictly the toolchain pin, not implementing this ADR's own deferred fix, which is real, separate design work (per "Two viable directions," above) still worth its own dedicated round now that the tool to verify it against exists.
