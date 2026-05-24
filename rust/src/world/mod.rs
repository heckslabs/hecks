//! World grammar — the `.world` file family (IR + parser), carved out of
//! the runtime core into its own GROW concern (loc_ratchet `world`).
//!
//! A `.world` declares runtime configuration — extension options, heki data
//! location, strategic descriptors, and (i610) the MCP servers a domain
//! wires — that sits alongside the `.bluebook` (domain definition) and
//! `.hecksagon` (wiring) files.
//!
//! Module layout:
//!   - `ir`         — the World / McpServer / Concern / ExtensionConfig IR
//!   - `parser`     — line-oriented reader producing the IR
//!   - `parser_mcp` — the `mcp do; server :name do; ... end end` sub-grammar
//!
//! Crate-stable re-exports keep `storehouse::world::ir::World` etc. callable
//! from `main.rs`, the projection emitters, and the test harness without each
//! consumer reaching into the file layout.

pub mod ir;
#[cfg(not(target_arch = "wasm32"))]
pub mod parser;
#[cfg(not(target_arch = "wasm32"))]
pub mod parser_mcp;
#[cfg(not(target_arch = "wasm32"))]
pub mod attach;
