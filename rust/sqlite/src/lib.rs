#![allow(clippy::doc_overindented_list_items)]
#![allow(clippy::doc_lazy_continuation)]


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
