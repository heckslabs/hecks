# The host core names no driver, and the era store is a port

**Status:** Proposed. Built on this branch: the Postgres journal and era SQL under `store/`, the
`tokio_postgres` entry in the boundary scan, `LineageStore::first_existing_states`, and
`lib/hecks/ports/dispatch.port`. Not built: steps 2 to 4 below. Date: 2026-10-28.

## Context

An outside review of the ports and adapters found the hexagon held in the Ruby runtime and in
`dispatch.rs`, and leaking in four places:

1. The host's boundary was a source scan inside one crate, and the scan did not forbid
   `tokio_postgres`. `journal.rs`, `mint.rs` and `presentation.rs` imported it while the scan
   called them runtime modules.
2. `Ports::Dispatch` was a Ruby module with no `.port` declaration.
3. Eras, lineage, minting and the auth head-view SQL are reachable only through
   `Store::lineage()`, which exists on Postgres alone. Era versioning is a domain idea, so a
   Memory-only run cannot exercise part of the domain's own meaning.
4. `expr_json.rs` re-implements the kernel's evaluator. That is a second copy of a rule, not an
   adapter, and it has already produced Ruby/Rust disagreements.

## Decision

1. **Host: the journal's data and names stay in `journal.rs`; its SQL is the Postgres adapter.**
   `journal_sql.rs` and `mint.rs` live under `store/` and re-export the data module, so adapter-side
   callers say `store::journal_sql`. Runtime modules keep `crate::journal` for types and names only.
   The boundary scan forbids `tokio_postgres` in every runtime module.
2. **Host: `presentation` reads head states through `LineageStore`.** The SQL and the
   `to_regclass` probe are the store's; the candidate relation names stay in `presentation`, where
   they are pure and tested.
3. **Ports: `dispatch` is declared.** `dispatch.port` names the `dispatched_by` verb and the
   `dispatcher` answer, like the other ports. The world parity spec shows no new difference between the Ruby and Rust
   readings; its five failures are the known json 2.7.2 empty-array formatting. No world in the
   corpus binds `dispatched_by`, so the Rust parser's reading of that verb is not yet exercised.

## Not yet decided, in order

- **An `EraStore` port with a Memory implementation.** It covers `current_era`, `held_eras`,
  `last_ordinal`, the lineage mutation append and the head reads. `Store::lineage()` then returns
  the port on every backend, and the Postgres-only escape hatch goes. The conformance suite gains
  era cases that run on both backends.
- **A core crate and an adapters crate.** `rust/host` becomes a core (dispatch, journal data,
  IR, expression and presentation code, the `Store` trait) that cannot name `axum`, `reqwest`,
  `tokio_postgres` or the AWS SDK, because they are not in its `Cargo.toml`. The compiler then
  holds the line the scan holds today, as `rust/tests/kernel_dependencies.rs` already does for the
  kernel. The scan stays as a second check on the core's own source.
- **`expr_json.rs` against the kernel evaluator.** Feature-sized (see the thin adapters notes:
  `Value::Object`, `Fielded`, error wording, the 152-case conformance spec). Until it lands, the
  conformance spec is what keeps the two copies from drifting.

## Consequences

- A new SQL call in a runtime module fails the boundary test, naming the file and line.
- Moving `mint.rs` and `journal.rs` changes a path that `bin/mint_harness.rs` and
  `bin/lineage_harness.rs` include by `#[path]`; both now include `store/journal_sql.rs` beside
  `journal.rs`.
- The 12 host tests that fail on a stale `rust/dist` fail identically before and after.
