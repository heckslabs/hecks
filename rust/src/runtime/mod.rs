pub use std::collections::HashMap;

pub mod dispatcher;
pub mod era_check;
pub mod era_guard;
pub mod identity;
pub mod storage_shape;
pub mod strict_boot;
pub mod mutations;
pub mod value_bridge;

#[allow(dead_code)]
pub mod aggregate_state;
#[allow(dead_code)]
pub use crate::ports::persistence::persistence_adapter;
#[allow(dead_code)]
pub mod query_match;
#[allow(dead_code)]
pub mod value;
#[allow(dead_code)]
pub mod value_convert;

#[allow(unused_imports)]
pub use crate::ports::persistence::persistence_adapter::{
    register_persistence_adapter, PersistenceAdapter, PersistenceSpec,
};
#[allow(unused_imports)]
pub use aggregate_state::AggregateState;
#[allow(unused_imports)]
pub use query_match::where_matches;
#[allow(unused_imports)]
pub use value::Value;
