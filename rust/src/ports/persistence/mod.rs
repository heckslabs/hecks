
pub use crate::runtime::aggregate_state::AggregateState;
pub use crate::runtime::value::Value;

mod persistence;
pub use persistence::{resolve_for, Persistence, DEFAULT_ADAPTER};

#[allow(dead_code)]
pub mod persistence_adapter;

#[cfg(test)]
mod tests;
