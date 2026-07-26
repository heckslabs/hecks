//! runtime - the persistence core, cherry-picked from Hecks.
//!
//! Hecks's runtime is 136 files and 22,903 lines: the whole storehouse. Taking
//! it wholesale would turn hecksagain INTO Hecks, which is not a rewrite. What
//! came over is the bounded closure the persistence adapters actually need:
//!
//!   value.rs               the runtime Value
//!   aggregate_state.rs     the state bag a repository stores
//!   persistence_adapter.rs the PersistenceAdapter trait, its spec, its registry
//!   query_match.rs         where_matches - the query oracle adapters answer to
//!
//! All four came over unedited. This file is the only hand-written part, and it
//! is glue rather than knowledge: it declares which modules were brought and
//! re-exports what they expose, standing in for the 136-module mod.rs that
//! would have dragged the rest of the runtime with it.

// The copied files reach their parent with `use super::*`, so they expect what
// Hecks's runtime/mod.rs has in scope. This is that preamble, and the reason
// none of them needed an edit.
pub use std::collections::HashMap;

// Ours, mirroring lib/hecksagain/runtime/ on the Ruby side.
pub mod dispatcher;
pub mod mutations;
pub mod value_bridge;

// Cherry-picked from Hecks, unedited. They carry helpers this runtime does not
// call — dead HERE, load-bearing THERE — and trimming them would fork the
// source, so the allow is by name on exactly these modules.
#[allow(dead_code)]
pub mod aggregate_state;
#[allow(dead_code)]
pub mod persistence_adapter;
#[allow(dead_code)]
pub mod query_match;
#[allow(dead_code)]
pub mod value;
#[allow(dead_code)]
pub mod value_convert;

// The seam the storehouse-sqlite crate consumes: `use storehouse::runtime::{
// PersistenceAdapter, PersistenceSpec, register_persistence_adapter,
// where_matches, Value, AggregateState }`. Unused until that crate is wired,
// and named here rather than added later so the shape it must satisfy is
// visible now.
#[allow(unused_imports)]
pub use aggregate_state::AggregateState;
#[allow(unused_imports)]
pub use persistence_adapter::{
    register_persistence_adapter, PersistenceAdapter, PersistenceSpec,
};
#[allow(unused_imports)]
pub use query_match::where_matches;
#[allow(unused_imports)]
pub use value::Value;
