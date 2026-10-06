# Coverage-guided fuzzing for hecks-parse

Opt-in. The parser stays dependency-free (ADR 0012); `libfuzzer-sys` lives only in this crate,
which is its own workspace and is never built by `cargo build` or `cargo test` in `rust/parser`.

```sh
rustup toolchain install nightly
cargo install cargo-fuzz
cd rust/parser
cargo +nightly fuzz run chapter -- -max_total_time=60   # bluebook parse + determinism
cargo +nightly fuzz run resolve -- -max_total_time=60   # hecksagon `attaches` resolution
```

Seed a run from the fixtures: `cargo +nightly fuzz run chapter ../tests/fixtures`. A crash lands
in `fuzz/artifacts/`; copy it to a `.bluebook` and run `hecks-parse chapter --chapter Fuzzed
<file>` to reproduce it.

The seeded harness in `tests/fuzz.rs` is what CI runs; this directory is for longer
coverage-guided hunts.
