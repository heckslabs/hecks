# A projection answers what the loop answers

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24. Closes known gap 2 (`client_native_read_model` in [verification](../implemented/guides/verification.md)). Builds on [0055](0055-read-model-on-target-for-where-order-by-limit-offset.md) and [0078](0078-read-model-completes-its-reduction-vocabulary-sum-avg-min-max-percentile-any-all.md).

## Context

A rooted read model over an aggregate `projected_by "SqliteProjection"` is answered two ways. When the projection is current, `ReadModelInterpreter` hands the whole model to the adapter's `query_read_model`, which reads its own tables. When it is not, or when the model groups or reduces, the in-process loop answers, reading whichever repository `Registry#read_repository` picks. Nothing checked that the two answers agree. A wrong join in the adapter, a column that decodes differently, or a projection that drops a field would answer a different report from the one the domain's own records compose, and every fuzz run rebinds projections away (`IsolatedBoot#rewrite_bindings!` drops `projected_by`), so no generated sequence ever reached the adapter.

The `projection` port also had one adapter. A Postgres application had no read store to project into, short of writing one.

## Decision

1. **Agreement is a fuzz property, `projected_read_models_agree_with_loop`.** `Fuzzing::ProjectionAgreement.check(domain, steps, projection:)` boots a copy of the domain on Memory, binds every chapter `projected_by` the named projection adapter, replays the steps, catches every projection up with the `:strict` worker, and then, for every rooted read model and every record its reference can name, compares two answers as plain JSON: the registry's (the adapter's own path when it has one, otherwise the loop over the projection's rows) and the loop over the authoritative repositories alone. Reducing models (`count`, `median`, the 0078 reductions) are compared the same way, so a projection that loses a reduced field is caught. A projection still not current after catch-up is its own finding, because the comparison would otherwise silently test the loop against itself.
2. **`hecks fuzz_run.fuzz! adapter.value=sqlite` runs it on `SqliteProjection`** beside the standard battery, and `adapter.value=postgres` runs it on the new Postgres projection. The Memory sweep does not: it has no projection adapter to compare.
3. **`PostgresProjection` is a second adapter on the `projection` port.** It is `Postgres` storage with the same `query_read_model` as `SqliteProjection`. The dialect-free read-model walk (root first, each head joined against heads already read, a head's `where`/`order_by`/`limit`/`offset` applied in process) moves into one shared module; each adapter supplies only how it selects a row and decodes a column. It is wired exactly as `SqliteProjection` is: `projected_by "PostgresProjection"` in the hecksagon and `projected_by("PostgresProjection") { database ...; schema ... }` in the world.
4. **The client profile retires `client_native_read_model`.** That rule refused a read model a native projection answers because nothing checked it, and the profile deletes a rule once its bug is fixed. The profile stays as an entry point with no open rule.
5. **A projection worker reads the registry's own authoritative repository.** A second authoritative repository built for the worker is, for an in-process store (Memory), a fresh empty one, so a Memory-backed projection would catch up to nothing. The worker catches up from `registry.repository`, the store the commands wrote.

## Alternatives considered

- **Push the reductions down into SQL.** It would make the adapter answer more, but `sum`/`avg` agreement with Rust is held by computing them one way (0078); a second engine computing them is a second thing to agree. Rejected; reductions keep running in the loop, now over checked rows.
- **A property over the replayed history.** The standard battery reads a history after the runtime is gone, and the answer the adapter gives needs a live registry with the projection bound. Rejected for a check that holds the runtime.
- **A Postgres projection that shares the `Postgres` persistence class directly.** A port-specific subclass is how `SqlitePersistence`/`SqliteProjection` advertise one contract each; doing the same keeps the wiring symmetric.

## Consequences

- A projection that answers differently from the domain's records fails a SQLite fuzz sweep, and a Postgres one behind the usual reachability gate.
- The Rust host has no projection adapter, so there is nothing on the Rust side to agree with; no grammar word is added.
- A future `D1Projection` gets the agreement check once it is added to `ProjectionAgreement::ADAPTERS`.
- `docs/1.0-readiness.md` still lists known gap 2 until the closing step updates it.
