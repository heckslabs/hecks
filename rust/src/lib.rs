//! storehouse - the library half of the hecksagain runtime.
//!
//! Named `storehouse` on purpose. The adapters cherry-picked from Hecks import
//! `storehouse::runtime::{PersistenceAdapter, Value, AggregateState}` and
//! `storehouse::ir`, so exposing the crate under that name is what lets them
//! come over UNEDITED. Renaming their imports would have been the first edit,
//! and the first edit is how a cherry-pick becomes a fork.
//!
//! The binary (main.rs) is a thin driver over this.

#[allow(dead_code)]
pub mod clock;
#[allow(dead_code)]
pub mod dump;
#[allow(dead_code)]
pub mod heki;
#[allow(dead_code)]
pub mod hecksagon_helpers;
#[allow(dead_code)]
pub mod hecksagon_ir;
#[allow(dead_code)]
pub mod hecksagon_parser;
#[allow(dead_code)]
pub mod ir;
#[allow(dead_code)]
pub mod parse_blocks;
#[allow(dead_code)]
pub mod parser;
#[allow(dead_code)]
pub mod parser_helpers;
#[allow(dead_code)]
pub mod pattern_subset;
#[allow(dead_code)]
pub mod runtime;
#[allow(dead_code)]
pub mod util;
#[allow(dead_code)]
pub mod world;

pub mod dispatcher;
pub mod interp_expr;
pub mod interp_givens;
pub mod interp_mutations;
pub mod ir_json;
pub mod value_bridge;
pub mod wiring;

#[cfg(test)]
mod interp_tests;
#[cfg(test)]
mod wiring_tests;
