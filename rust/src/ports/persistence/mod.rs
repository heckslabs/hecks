pub use crate::runtime::aggregate_state::AggregateState;
pub use crate::runtime::value::Value;
pub use persistence_adapter::ReplicationEntry;

mod persistence;
pub use persistence::{resolve_all_for, resolve_for, Persistence, PersistenceBindings, DEFAULT_ADAPTER};

mod lineage;
pub use lineage::Lineage;

#[allow(dead_code)]
pub mod persistence_adapter;

#[cfg(test)]
mod tests;
