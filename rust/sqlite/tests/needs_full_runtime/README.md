# Tests that need Hecks's full Runtime

Cargo only auto-discovers `*.rs` directly under `tests/`, so a file here is
parked rather than deleted — UNEDITED, so it can move back the moment its
dependencies exist.

`sqlite_scope_test.rs` imports `storehouse::corpus_loader`,
`storehouse::runtime::{Runtime, RuntimeError, repo_key}` and
`storehouse_router`. Those belong to the 22,903-line runtime hecksagain did
not bring over — see rust/src/runtime/mod.rs for where that boundary was drawn
and why.

Everything else in this crate runs: 21 unit tests (including the SQL-pushdown
vs in-memory-oracle parity tests) and 3 in tests/sqlite_repository_test.rs.
