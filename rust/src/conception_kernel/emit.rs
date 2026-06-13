//! conception_kernel::emit — per-command rendering, plan-independent.
//!
//! The DATA-layer rendering helpers that turn one command's IR + the
//! SampleValueRule table into behaviors source fragments: the setup line, the
//! input kwargs, and the kv formatting. None of these depend on the setup-chain
//! PLAN — they render a single given command — so they move into the kernel
//! ahead of the planner switch. `generator.rs` delegates to them until it is
//! deleted at the final gate.
//!
//! Usage:
//!   let line = conception_kernel::emit::setup_line(cmd); // "    setup  \"X\", k: v"

use crate::conception_kernel::sample::sample_value;
use crate::ir::Command;

/// `[(k, v), ...]` -> `"k: v, k2: v2"`.
pub fn join_kvs(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}: {}", k, v))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A setup line for a chain command — `setup "Cmd", attr: sample, ...`.
/// The aggregate is irrelevant to rendering (kept out of the signature); only
/// the command's own attributes shape the line.
pub fn setup_line(cmd: &Command) -> String {
    let pairs: Vec<(String, String)> = cmd
        .attributes
        .iter()
        .map(|attr| (attr.name.clone(), sample_value(&attr.attr_type)))
        .collect();
    let kvs = if pairs.is_empty() {
        String::new()
    } else {
        format!(", {}", join_kvs(&pairs))
    };
    format!("    setup  {:?}{}", cmd.name, kvs)
}

/// Inputs for the command under test — domain attrs only. References are NOT
/// emitted: the bluebook layer is reference-only (no ids) and the runner
/// resolves them from its in-scope aggregate map at dispatch time.
pub fn input_pairs(cmd: &Command) -> Vec<(String, String)> {
    cmd.attributes
        .iter()
        .map(|attr| (attr.name.clone(), sample_value(&attr.attr_type)))
        .collect()
}

/// kwargs prepended with `, ` for use after a positional first arg. Domain
/// attrs only — references are injected by the runner, never typed in source.
pub fn kwargs_inline(cmd: &Command) -> String {
    if cmd.attributes.is_empty() {
        return String::new();
    }
    let kvs: Vec<(String, String)> = cmd
        .attributes
        .iter()
        .map(|a| (a.name.clone(), sample_value(&a.attr_type)))
        .collect();
    format!(", {}", join_kvs(&kvs))
}
