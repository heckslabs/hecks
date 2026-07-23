// Doc-rendering lints allowed for the same reason as the lib crate root: these
// comments are read as source, not rendered by `cargo doc`.
#![allow(clippy::doc_overindented_list_items)]
#![allow(clippy::doc_lazy_continuation)]

//! storehouse-sqlite — the SQLite persistence adapter for the storehouse
//! runtime.
//!
//! Implements the `storehouse::runtime::PersistenceAdapter` port with a typed-
//! column SQL backend (one column per attribute, derived from the bluebook IR —
//! never a JSON blob) and registers itself under the `sqlite` hexagon token via
//! [`register`]. The runtime lib carries NO SQL : this crate owns `rusqlite` and
//! is linked + registered only by the composition root (storehouse-cli), never
//! by the wasm Worker.
//!
//! Usage (composition root) :
//!   storehouse_sqlite::register();   // before Runtime::boot
//!   // a hexagon `adapter :sqlite, db: "app.db"` now resolves to this backend.

mod sql_query;
mod sqlite_mapping;
mod sqlite_query;
mod sqlite_repository;

#[cfg(test)]
mod query_parity_tests;
#[cfg(test)]
mod sql_query_tests;

pub use sqlite_mapping::sql_type;
pub use sqlite_repository::{register, sqlite_factory, SqliteRepository};
