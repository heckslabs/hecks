//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.
//!
//! ## wasm32 boundary (DailyMusing CF Worker / i528)
//!
//! On `wasm32-unknown-unknown` (the Cloudflare Worker target) only
//! the dispatch core compiles : parser → IR → runtime (in-memory
//! repository), heki (snake_case + Value + wire format), heki_r2
//! (R2 adapter), the hecksagon / fixtures parsers, the cascade /
//! projection / lifecycle support, and the server's HTML serializers
//! (read-only render — no TcpListener). Everything else — the CLI
//! `run_*` commands, the multi-domain TCP server, the conceiver /
//! behaviors / validator / specializer toolchains — pulls in
//! std::fs / std::process / std::net / threads / rusqlite, none of
//! which exist on Workers, so they are gated out with
//! `#[cfg(not(target_arch = "wasm32"))]`.

pub mod parser_helpers;
pub mod parse_blocks;
pub mod parser;
pub mod ir;
pub mod runtime;
pub mod json_helpers;
pub mod server;
#[cfg(not(target_arch = "wasm32"))]
pub mod validator;
#[cfg(not(target_arch = "wasm32"))]
pub mod validator_warnings;
#[cfg(not(target_arch = "wasm32"))]
pub mod validator_corpus;
#[cfg(not(target_arch = "wasm32"))]
pub mod conceiver;
pub mod clock;
pub mod util;
pub mod run_integrity;
pub mod heki;
// heki_r2 — R2-backed sibling of heki, used inside Cloudflare
// Workers. Cfg-gated to wasm32 because the `worker::Bucket` it
// depends on only exists at that target. See rust/src/heki_r2.rs
// for the i528 R2 storage adapter contract.
#[cfg(target_arch = "wasm32")]
pub mod heki_r2;
#[cfg(not(target_arch = "wasm32"))]
pub mod heki_query;
#[cfg(not(target_arch = "wasm32"))]
pub mod dispatch_query;
#[cfg(not(target_arch = "wasm32"))]
pub mod dump;
#[cfg(not(target_arch = "wasm32"))]
pub mod conceiver_common;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_ir;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_parser;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_dump;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_conceiver;

pub mod conception_kernel;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_runner;
#[cfg(not(target_arch = "wasm32"))]
pub mod behaviors_fixtures;
pub mod diagnostic;
#[cfg(not(target_arch = "wasm32"))]
pub mod io_validator;
pub mod lifecycle_validator;
#[cfg(not(target_arch = "wasm32"))]
pub mod duplicate_policy_validator;
pub mod cascade;
pub mod fixtures_ir;
pub mod fixtures_parser;
pub mod hecksagon_helpers;
pub mod hecksagon_ir;
pub mod hecksagon_parser;
pub mod world;
// f4 — aggregate-level invariant evaluation. Carved into its own dir as a
// GROW concern in loc_ratchet.fixtures (same pattern as world /
// adapter_resolution) : the invariant evaluator grows with the f4 rule
// surface rather than fighting core_runtime's shrink pressure.
pub mod invariants;
#[cfg(not(target_arch = "wasm32"))]
pub mod adapter_resolution;
pub mod projection;
#[cfg(not(target_arch = "wasm32"))]
pub mod run;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_boot;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_follow;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_mailboxes;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_restructure;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_serve;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_status;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_statusline;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_stdin_loop;
#[cfg(not(target_arch = "wasm32"))]
pub mod run_wake;
#[cfg(not(target_arch = "wasm32"))]
pub mod specializer;
#[cfg(not(target_arch = "wasm32"))]
pub mod corpus_loader;

pub mod story_runtime;
#[cfg(not(target_arch = "wasm32"))]
pub mod storehouse_router;
#[cfg(not(target_arch = "wasm32"))]
pub mod storehouse_query;
