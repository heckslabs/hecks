//! Script-mode runner — `hecks-life run <file.bluebook> [key=val ...]`
//!
//! Reads a .bluebook, strips its shebang, finds the companion
//! .hecksagon (sibling file with the same stem), parses both, wires
//! adapters through the runtime, and dispatches the bluebook's
//! `entrypoint` command with attrs bound from argv.
//!
//! Exit codes:
//!   0 clean
//!   1 parse failure (bluebook or hecksagon)
//!   2 guard failure (no entrypoint, gate denied)
//!   3 adapter failure (shell non-zero, timeout, etc.)
//!   4 command not found
//!
//! Shebang form:
//!   #!/usr/bin/env hecks-life run
//!   Hecks.bluebook "Whatever" do
//!     entrypoint "MainCommand"
//!     ...
//!   end
//!
//! Companion hecksagon discovery:
//!   `<stem>.hecksagon` — same directory, same stem.

use crate::hecksagon_ir::Hecksagon;
use crate::ir::Domain;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{Runtime, Value};
use crate::{hecksagon_parser, parser};

use std::collections::HashMap;
use std::path::Path;

/// Exit code shape — see module docs.
#[derive(Debug, Clone, Copy)]
pub enum ExitKind {
    Ok,
    ParseFailure,
    GuardFailure,
    AdapterFailure,
    CommandNotFound,
}

impl ExitKind {
    pub fn code(self) -> i32 {
        match self {
            ExitKind::Ok => 0,
            ExitKind::ParseFailure => 1,
            ExitKind::GuardFailure => 2,
            ExitKind::AdapterFailure => 3,
            ExitKind::CommandNotFound => 4,
        }
    }
}

/// Parse a bluebook and its companion .hecksagon (if present) and
/// return the wired runtime + adapter registry. Caller dispatches.
pub fn load_script(path: &str) -> Result<(Domain, Hecksagon), ExitKind> {
    let source = std::fs::read_to_string(path).map_err(|e| {
        eprintln!("hecks-life run: cannot read {}: {}", path, e);
        ExitKind::ParseFailure
    })?;
    let domain = parser::parse(&source);
    if domain.name.is_empty() {
        eprintln!("hecks-life run: {} is not a bluebook (Hecks.bluebook header missing)", path);
        return Err(ExitKind::ParseFailure);
    }
    let hex = companion_hecksagon(path);
    Ok((domain, hex))
}

/// Locate `<stem>.hecksagon` next to the given bluebook path. Returns a
/// blank Hecksagon when no companion exists — that's fine for pure-
/// memory scripts.
pub fn companion_hecksagon(bluebook_path: &str) -> Hecksagon {
    let p = Path::new(bluebook_path);
    let parent = p.parent().unwrap_or_else(|| Path::new("."));
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let candidate = parent.join(format!("{}.hecksagon", stem));
    if candidate.exists() {
        match std::fs::read_to_string(&candidate) {
            Ok(src) => hecksagon_parser::parse(&src),
            Err(_) => Hecksagon::default(),
        }
    } else {
        Hecksagon::default()
    }
}

/// Full entry point: argv is `["hecks-life", "run", path, ...attrs]`.
/// Returns the exit code the caller should propagate to the OS.
pub fn run_script(args: &[String]) -> i32 {
    if args.len() < 3 {
        eprintln!("Usage: hecks-life run <file.bluebook> [key=val ...]");
        return ExitKind::ParseFailure.code();
    }
    let path = &args[2];
    let extra = &args[3..];

    let (domain, hex) = match load_script(path) {
        Ok(x) => x,
        Err(e) => return e.code(),
    };
    let entrypoint = match domain.entrypoint.clone() {
        Some(e) => e,
        None => {
            eprintln!("hecks-life run: {} declares no `entrypoint \"…\"`", path);
            return ExitKind::GuardFailure.code();
        }
    };

    // Attrs from argv: each `key=val` pair becomes a Value::Str. This
    // mirrors the bluebook-dispatch loop in main.rs.
    let attrs: HashMap<String, Value> = extra.iter().filter_map(|a| {
        let mut parts = a.splitn(2, '=');
        let k = parts.next()?;
        let v = parts.next()?;
        Some((k.to_string(), Value::Str(v.to_string())))
    }).collect();

    let registry = AdapterRegistry::from_hecksagon(hex);
    let data_dir = infer_data_dir(path);
    let mut rt = Runtime::boot_with_data_dir(domain, data_dir);

    match rt.dispatch(&entrypoint, attrs) {
        Ok(_) => {
            // Non-persistence IO adapters don't need cleanup on the
            // happy path — stdout/stderr have already flushed. For the
            // stdin-loop case, the capability's own policy engine fires
            // EndSession via the entrypoint command.
            let _ = registry;
            ExitKind::Ok.code()
        }
        Err(crate::runtime::RuntimeError::UnknownCommand(_)) => {
            eprintln!("hecks-life run: entrypoint {} not found in {}", entrypoint, path);
            ExitKind::CommandNotFound.code()
        }
        Err(e) => {
            eprintln!("hecks-life run: {}", e);
            ExitKind::AdapterFailure.code()
        }
    }
}

/// Pick a data dir for heki persistence — prefer a sibling
/// `information/` (Miette convention), otherwise fall back to
/// `<parent>/data`.
fn infer_data_dir(bluebook_path: &str) -> Option<String> {
    let p = Path::new(bluebook_path);
    let parent = p.parent()?;
    let info = parent.join("information");
    if info.is_dir() {
        return Some(info.to_string_lossy().into());
    }
    Some(parent.join("data").to_string_lossy().into())
}
