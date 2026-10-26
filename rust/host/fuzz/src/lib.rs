//! Differential fuzzing of the host's journal backends: the in-memory store is the fast oracle, the
//! Postgres store is checked against it only for command scripts that are new in shape.
//!
//! - [`ops`] turns libFuzzer's bytes into a typed script of Banking commands (`arbitrary`).
//! - [`backend`] is the one seam both stores sit behind: [`backend::MemoryBackend`] over the host's
//!   own `MemoryStore`, and [`backend::PostgresBackend`] over its `PostgresStore`.
//! - [`footprint`] hashes a script's structure and remembers which footprints Postgres has already
//!   agreed with.
//! - [`equivalence`] plays a script and compares.
//!
//! Nothing here names a table or a keyword of the language: the harness speaks only to the host's
//! public dispatch path and its `Store`, the way a caller of the host does.

pub mod backend;
pub mod equivalence;
pub mod footprint;
pub mod ops;
