//! world - the per-deployment values, cherry-picked from Hecks.
//!
//! attach.rs and parser_mcp.rs are deliberately NOT brought over: they reach
//! into Hecks' runtime, which this project does not have.
pub mod ir;
pub mod parser_mcp;
pub mod parser;
