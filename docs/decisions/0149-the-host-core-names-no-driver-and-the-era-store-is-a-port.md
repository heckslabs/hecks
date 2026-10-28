# The host core names no driver, and the era store is a port

**Status:** Accepted. Built: the Postgres journal and era SQL under `store/`, the
`tokio_postgres` entry in the boundary scan, `dispatch.port`, the era store's heads, `Store` as a
handle over a `Backend` trait, and the split of `rust/host` into a core crate and the adapters.
and eras on Memory. Not built: the evaluator merge. Date: 2026-10-28.

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

5. **Host: the runtime is its own crate, `rust_host_core` (`rust/host/core`).** It holds `dispatch`,
   `host`, `journal` (data and names), `ir`, `expr_json`, `presentation`, `presentation_write`,
   `ui_schema`, `wasm_runner`, `plugins`, `query_step`, `lambda_client` (the invoker trait), the
   `Store` handle, the `Backend` traits and the Memory backend. Its dependency table has no
   Postgres, HTTP server or client, or AWS crate (`cargo tree` shows none), so a driver in the
   runtime is a compile error. `rust/host` stays the adapters crate with the same package, library
   and `bootstrap` binary names, so the CI paths and `--manifest-path` calls are unchanged; it
   re-exports the core's modules at their old paths, and adds `store::{postgres, journal_sql, mint}`,
   `store::postgres_store` and the transports. The two crates are one Cargo workspace (core is a
   path dependency), so CI runs `cargo test --workspace`.
   - The tests that need Postgres moved with their backend: `dispatch_tests.rs` and
     `presentation_tests.rs` in the adapters crate. The core's own 249 tests need no database.
   - What the adapters' tests borrow from the core (`NeverInvoker`, `FixedClock`, the Memory
     test hooks, the wasm fixture helper) sits behind a `test-support` feature the adapters enable as
     a dev-dependency.
   - The harness binaries used `#[path]` includes because there was no library split; they now
     depend on the two crates.
   - The boundary scan stays as a second check, now reading the core's sources.
   - `plugins.rs` and `wasm_runner.rs` call `std::env::temp_dir`, which is not a transport but is the
     process environment. They are in the core on purpose; the scan covers neither.

6. **Host: Memory holds eras.** `Backend` gains `held_eras` and `current_era`, which Postgres
   answers from `hecks_eras` and Memory from its own table. A Memory store boots the way Postgres
   does when the domain needs lineage (a lineage-capable aggregate, or Google sign-in): the pure
   `decide_boot_action` picks `UseExisting` (a held era names this shape) or `HoldFirst`, and
   `MemoryStore::hold_era` records it. A Memory store keeps no translation edges, so a process
   that boots a second shape against the same store is refused with a message that says so.
   With an era active, a committed step's lineage mutations land in Memory's heads, so member
   sign-in and the lineage-capable aggregates work on Memory. `select_backend` no longer refuses
   them (`has_lineage` and the `google_auth` parameter are gone), and `boot_memory_era` takes the
   Google flag as an argument so tests do not read the process environment. Minting later eras,
   the ledger seals and `store/mint.rs` stay Postgres provisioning.

## Not yet decided, in order

- **Done: `Store` is a handle over a `Backend` trait.** `Store` is a struct holding a
  `Box<dyn Backend>`, and `Unit` holds a `Box<dyn UnitBackend>`; the Postgres and Memory backends
  implement them, and no call site changed. `amend_head` crosses the trait as a `&mut dyn FnMut`
  decision (a generic closure is not object-safe); `Store::amend_head<T>` keeps its typed
  signature and carries the answer out. What still names a driver in `store.rs`: the
  `Store::postgres` constructor, `lineage()` and the cfg(test) fixtures, which downcast to the
  concrete backends, and `StoreError`'s conversion from `tokio_postgres::Error`. Those move to the
  adapters crate in the next step.
- **Done: one expression evaluator, the `hecks_expr` crate (`rust/expr`).** It holds `Expr`,
  `Value` (with a new `Object` variant), the operators, the attribute shapes, `ruby_float`,
  `rendering` and `Refusal`. The kernel depends on it alone and re-exports its modules at the old
  paths, so generated code is unchanged; `rust_host_core` depends on it too. The host's
  `expr_json.rs` is now only its JSON door: `parse` builds the shared `Expr` (names interned to
  `&'static str`, once each) and `interpret` evaluates it over an instance read as a `Fielded`
  tree. `Wasm.scratch_copy` carries the new crate, the kernel-capability files live at
  `rust/expr/src`, and the kernel dependency test holds both crates.
  Merging them exposed where the kernel had drifted from Ruby, and the shared crate now follows
  Ruby: float printing switched to scientific notation a decade late (1e15), `%` truncated floats,
  `.split(" ")` ignored whitespace runs, regex `^`/`$`/`\d`/`m` were not Ruby's, integer/float
  equality lost precision past 2^53, a path past an integer or list read as nil instead of
  refusing, `.include?` on a non-list raised instead of answering false, and error messages
  printed Rust `Debug` instead of Ruby's `describe`. The 210-case Ruby parity spec for the host,
  and the kernel's operator, numeric, conformance and semantics-corpus specs, all pass.
- **Superseded: `expr_json.rs` against the kernel evaluator.** Feature-sized (see the thin adapters notes:
  `Value::Object`, `Fielded`, error wording, the 152-case conformance spec). Until it lands, the
  conformance spec is what keeps the two copies from drifting.

## Consequences

- A new SQL call in a runtime module fails the boundary test, naming the file and line.
- Moving `mint.rs` and `journal.rs` changes a path that `bin/mint_harness.rs` and
  `bin/lineage_harness.rs` include by `#[path]`; both now include `store/journal_sql.rs` beside
  `journal.rs`.
- The 12 host tests that fail on a stale `rust/dist` fail identically before and after.
