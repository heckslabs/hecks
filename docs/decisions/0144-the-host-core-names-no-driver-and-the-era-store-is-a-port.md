# The host core names no driver, and the era store is a port

**Status:** Proposed. Built on this branch: the Postgres journal and era SQL under `store/`, the
`tokio_postgres` entry in the boundary scan, `LineageStore::first_existing_states`, and
`lib/hecks/ports/dispatch.port`, and the era store's heads. Not built: eras on Memory (undecided), the
crate split and the evaluator merge. Date: 2026-10-28.

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

4. **Host: the era store's head surface is on `Store`, on both backends.** `head_by_id`,
   `head_all`, `head_find`, `put_head` and `amend_head` (read the heads, decide, write at most one
   row, atomically) replace the raw connection in the member and sign-in code in `auth.rs`, and `head_states` does the
   same for `presentation`.
   Memory keeps heads in process and fills them from a committed step's lineage mutations.
   `store_conformance` runs five head cases on Postgres and Memory. They found one divergence,
   now fixed: `head_all` answers in id byte order on both (Postgres had answered in storage order).
   `head_find` falls back to the plain `<storage>_head` view on Postgres, which the session lookup
   did not before; a missing head view there now answers `None` instead of an error.

## Not yet decided, in order

- **The rest of the era store.** Heads are done for `auth.rs` and `presentation`, and no domain-side
  code takes a raw Postgres connection any more. What remains is Postgres provisioning that belongs
  to the adapter: boot's era decision (`held_eras`, `current_era`) and minting (`store/mint.rs`),
  and the ledger seals, which the Postgres commit and the operator tools run. Whether Memory should
  hold eras at all is open: it mints nothing today and `has_lineage` is false for it. If it should,
  eras move onto `Store` with a conformance case each; if not, `Store::lineage()` stays as the
  adapter's own handle and the port is complete.
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
