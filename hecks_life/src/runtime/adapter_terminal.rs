//! Terminal Adapter — thin back-compat shim over the shebang-run path.
//!
//! Prior to the shebang-runtime port this file held the stdin/stdout
//! loop directly in Rust. That logic now lives in
//! `hecks_life::run_stdin_loop` and is driven by the terminal
//! capability's .bluebook + .hecksagon pair (see
//! hecks_conception/capabilities/terminal/). This file exists only
//! so legacy callers (`hecks-life terminal` + `run_interactive`) keep
//! working — they synthesize an ambient hecksagon (:memory, :stdout,
//! :stdin, :stderr) and hand off to the run-loop runner.

use crate::hecksagon_ir::{Hecksagon, IoAdapter};
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{Runtime, Value};
use std::collections::HashMap;

/// Boot an ambient Hecksagon with :memory + :stdout + :stdin + :stderr
/// adapters and drive the interactive loop against the given runtime.
/// Callers come from:
///   * `hecks-life terminal <dir>` — the legacy CLI entry point
///   * `Runtime::run_interactive()` — the in-process REPL
///
/// New callers should use `hecks-life run path/to/terminal.bluebook`
/// instead so the capability shape stays declared in the bluebook.
pub fn run(rt: &mut Runtime, being: &str) {
    let hex = ambient_hecksagon();
    let registry = AdapterRegistry::from_hecksagon(hex);
    let mut attrs = HashMap::new();
    attrs.insert("being".into(), Value::Str(being.into()));
    let _ = crate::run_stdin_loop::run(rt, &registry, "StartSession", attrs);
}

/// Ambient hecksagon — the four adapters the old adapter_terminal.rs
/// used implicitly: memory persistence, stdin/stdout/stderr I/O.
fn ambient_hecksagon() -> Hecksagon {
    Hecksagon {
        name: "Terminal".into(),
        persistence: Some("memory".into()),
        io_adapters: vec![
            IoAdapter { kind: "stdout".into(), options: vec![], on_events: vec![] },
            IoAdapter { kind: "stdin".into(),  options: vec![], on_events: vec![] },
            IoAdapter { kind: "stderr".into(), options: vec![], on_events: vec![] },
        ],
        ..Hecksagon::default()
    }
}
