//! persistence - the port folder : the contract, and the resolution that spends
//! it. Mirrors lib/hecksagain/ports/persistence/.
//!
//!   persistence.rs           the EXECUTION - which adapter, and where it points
//!   persistence_adapter.rs   the CONTRACT - the trait a backend implements
//!
//! The trait file came from Hecks unedited and keeps its name, per the rule that
//! a cherry-picked file changes folder and nothing else. It reaches its parent
//! with `use super::AggregateState` / `use super::Value`, which is why those are
//! re-exported below : this mod.rs is the preamble the copied file expects, the
//! same seam runtime/mod.rs uses for the other four.

// The preamble the cherry-picked trait reaches for.
pub use crate::runtime::aggregate_state::AggregateState;
pub use crate::runtime::value::Value;

mod persistence;
pub use persistence::{resolve_for, Persistence, DEFAULT_ADAPTER};

// Cherry-picked from Hecks, unedited. It carries helpers this projection does
// not call - dead HERE, load-bearing THERE - so the allow is by name.
#[allow(dead_code)]
pub mod persistence_adapter;

#[cfg(test)]
mod tests;
