//! bluebook - what a bluebook IS, and how it is read.
//!
//! Mirrors lib/hecksagain/bluebook/ on the Ruby side, layer for layer. Ruby
//! BUILDS the IR through a DSL ; Rust BUILDS it through a parser. Same layer,
//! two ways in — which is the whole point of having both.
//!
//!   ruby                        rust
//!   bluebook/dsl/               bluebook/parser.rs, parse_blocks.rs
//!   bluebook/ir/                bluebook/ir.rs
//!   bluebook/expression/        bluebook/expression/
//!
//! Everything here except this file came over from Hecks unedited. The files
//! keep Hecks's NAMES (ir.rs, parse_blocks.rs, hecksagon_parser.rs) even though
//! they now sit in a mirrored folder, so re-syncing one is still a straight
//! copy — the folder moved, the file did not.

pub mod expression;
pub mod hecksagon_helpers;
pub mod hecksagon_ir;
pub mod hecksagon_parser;
pub mod ir;
pub mod parse_blocks;
pub mod parser;
pub mod parser_helpers;
pub mod pattern_subset;
pub mod world;
