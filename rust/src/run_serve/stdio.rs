//! run_serve::stdio — the stdin/stdout transport for the warm serve
//! loop.
//!
//! [antibody-exempt: rust/src/run_serve/stdio.rs — kernel-floor runtime
//!  perf transport. The original `serve-stdio` loop : read one request
//!  line from stdin, hand it to the shared `handle_request`, write one
//!  sentinel-prefixed result line to stdout. A bluebook can't describe
//!  its own process-lifetime stdio pump ; the dispatch BODY is the
//!  shared bluebook contract in mod.rs.]
//!
//! Usage : `storehouse::run_serve::run(&mut rt, Some(&legacy_hook))`.
//! Boots once (caller's responsibility), then loops over stdin lines.
//! The MCP used to spawn ONE of these per server — but Claude Code
//! starts the MCP, so the warm child died on every Claude restart. The
//! socket transport (sibling `socket.rs`) replaces that pattern with an
//! overmind daemon ; this stdio loop stays for direct/local use and as
//! the fallback shape the CLI still exposes.

use super::{handle_request, LegacyLlmHook, RESULT_SENTINEL};
use crate::runtime::Runtime;
use std::io::{self, BufRead, Write};

/// Run the resident serve loop against an already-booted runtime over
/// stdin/stdout.
///
/// `legacy_llm` is invoked after each command dispatch with
/// `(rt, aggregate_type, aggregate_id, command)` so the caller can run
/// the same post-dispatch LLM-adapter pass `dispatch_hecksagon` does.
pub fn run(rt: &mut Runtime, legacy_llm: Option<&LegacyLlmHook>) -> i32 {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    // Announce readiness on a sentinel line so the MCP child can wait
    // for the boot to finish before sending its first request.
    let _ = writeln!(stdout, "{}{{\"ready\":true}}", RESULT_SENTINEL);
    let _ = stdout.flush();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let req = line.trim();
        if req.is_empty() { continue; }

        let result_line = handle_request(rt, req, legacy_llm);
        // Single authoritative result line. Any adapter/log println!
        // the dispatch produced has already gone to stdout ABOVE this
        // line ; the sentinel lets the reader pick this one out.
        if writeln!(stdout, "{}", result_line).is_err() {
            break; // pipe closed — the parent went away.
        }
        if stdout.flush().is_err() { break; }
    }
    0
}
