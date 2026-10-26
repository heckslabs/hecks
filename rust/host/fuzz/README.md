# Differential fuzzing of the host's journal stores

Opt-in. The host stays free of fuzzing dependencies: `libfuzzer-sys`, `arbitrary`, `dashmap` and
`ahash` live only in this crate, which is its own workspace and is never built by `cargo build` or
`cargo test` in `rust/host`.

The in-memory store (`MemoryStore`, the oracle) runs every script. The Postgres store is compared
against it only for scripts whose structure has not been seen to agree. A script is a run of Banking
commands that `arbitrary` decodes from libFuzzer's bytes (`src/ops.rs`).

## Run it

Needs the compiled kernel and, for the comparison, a scratch Postgres database.

```sh
exe/hecks build.build_wasm domain=examples/banking profile=dev --wait   # rust/dist/banking.wasm
createdb hecks_fuzz

rustup toolchain install nightly --profile minimal
cargo install cargo-fuzz --locked
cd rust/host
HECKS_FUZZ_PG="host=localhost user=$USER dbname=hecks_fuzz" \
  cargo +nightly fuzz run postgres_equivalence --sanitizer none -- \
  -max_total_time=300 -timeout=30 -max_len=1024 > /dev/null
```

- `HECKS_FUZZ_PG` unset: only the in-memory store runs. That still checks the commit clause (an
  accepted command advances the snapshot by one row, any other leaves the store as it was) and, with
  the default sanitizer, memory safety.
- `HECKS_FUZZ_WASM` names another kernel; the default is `rust/dist/banking.wasm`.
- stdout goes to `/dev/null`: the host logs one JSON line a command. libFuzzer reports on stderr.
- A crash lands in `fuzz/artifacts/`; replay it with
  `cargo +nightly fuzz run postgres_equivalence fuzz/artifacts/postgres_equivalence/<file>`.

Without nightly, `cargo test --release --test smoke` drives the same check from a seeded byte stream
(`HECKS_FUZZ_SMOKE=3000` sets how many scripts).

## What it compares

Each step's outcome (accepted, refused with the kernel's answer, or failed), and afterwards the
snapshot's ordinal and seed and the live sagas, read through `Store::begin` and `load`.

- Event timestamps (`occurred_at`) are dropped: the stores are played moments apart.
- The in-memory store is played twice and must answer the same both times. Without that, a
  difference between the stores could be the kernel disagreeing with itself.
- A difference is played again on both stores before it is reported.

## What it does not cover

- The journal rows themselves: no public read returns them, so a `jsonb` round trip of journaled
  arguments is seen only through the snapshot.
- Lineage (`era: None`): the era-shaped mirror tables need `provision_lineage`, which is test-only.
- Crash durability: the Postgres session runs `synchronous_commit = off` on unlogged tables.
- Scripts that differ only in the value inside one class (a length bucket, a number's magnitude)
  share a footprint, so the memo re-verifies one in 1, 2, 4, 8... repeats instead of all of them.
