//! Phase 6 — EnsureDaemons
//!
//! For each `adapter :daemon, name:, pidfile:, command:` row declared
//! in the boot.hecksagon, shells out to `hecks-life daemon ensure
//! <pidfile> <command>` (the kernel-surface primitive added 2026-04-26
//! in `main.rs run_daemon`). The shell-out is the transitional shape ;
//! the deeper move is to call `daemon_ensure` directly from the
//! runtime so the runner doesn't fork a sibling hecks-life. File the
//! gap : "boot runner should call daemon ensure in-process — pull
//! daemon_ensure / spawn_detached out of main.rs into a runtime
//! adapter module."
//!
//! Placeholder substitution :
//!   {info}  → resolved info_dir
//!   {dir}   → conception dir (sibling of info_dir)
//!   {agg}   → conception/aggregates
//!   {hecks} → path to the running hecks-life binary

use crate::hecksagon_ir::IoAdapter;
use crate::runtime::adapter_registry::AdapterRegistry;

use std::path::Path;
use std::process::{Command, Stdio};

#[derive(Debug, Clone)]
pub struct DaemonStatus {
    pub name: String,
    pub status: String,
}

pub fn ensure_all(
    registry: &AdapterRegistry,
    script_path: &str,
    info_dir: &str,
) -> Vec<DaemonStatus> {
    let conception = conception_dir(script_path);
    let conception_str = conception.to_string_lossy().to_string();
    let agg_dir = conception.join("aggregates").to_string_lossy().to_string();
    let hecks_bin = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "hecks-life".to_string());

    let mut out = Vec::new();
    for adapter in registry.hecksagon.io_adapters.iter()
        .filter(|a| a.kind == "daemon") {
        // Skip the bare `adapter :daemon` declaration that has no name.
        let name = match adapter_option(adapter, "name") {
            Some(n) => strip_symbol(&n),
            None => continue,
        };
        if name.is_empty() { continue; }

        let pidfile = adapter_option(adapter, "pidfile")
            .map(|s| substitute(&s, info_dir, &conception_str, &agg_dir, &hecks_bin))
            .unwrap_or_default();
        let command = adapter_option(adapter, "command")
            .map(|s| substitute(&s, info_dir, &conception_str, &agg_dir, &hecks_bin))
            .unwrap_or_default();

        if pidfile.is_empty() || command.is_empty() {
            out.push(DaemonStatus {
                name: name.clone(),
                status: "skipped (incomplete adapter declaration)".into(),
            });
            continue;
        }

        let status = ensure_one(&pidfile, &command);
        out.push(DaemonStatus { name, status });
    }
    out
}

fn ensure_one(pidfile: &str, command_line: &str) -> String {
    // command_line is "<cmd> [args...]" — split on whitespace.
    let parts: Vec<&str> = command_line.split_whitespace().collect();
    if parts.is_empty() { return "skipped (empty command)".into(); }
    let hecks_bin = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "hecks-life".to_string());

    let mut cmd_args: Vec<String> = vec![
        "daemon".into(), "ensure".into(),
        pidfile.to_string(),
    ];
    for p in &parts { cmd_args.push((*p).to_string()); }

    let output = Command::new(&hecks_bin)
        .args(&cmd_args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if s.starts_with("alive") {
                format!("already running ({})", s.trim_start_matches("alive: "))
            } else if s.starts_with("spawned") {
                format!("started (pid {})", s.trim_start_matches("spawned: "))
            } else if s.is_empty() {
                "started".into()
            } else {
                s
            }
        }
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            format!("failed: {}", err)
        }
        Err(e) => format!("failed: {}", e),
    }
}

fn substitute(s: &str, info: &str, dir: &str, agg: &str, hecks: &str) -> String {
    s.trim_matches('"')
        .replace("{info}", info)
        .replace("{dir}", dir)
        .replace("{agg}", agg)
        .replace("{hecks}", hecks)
}

fn adapter_option(adapter: &IoAdapter, key: &str) -> Option<String> {
    adapter.options.iter().find(|(k, _)| k == key)
        .map(|(_, v)| v.clone())
}

fn strip_symbol(s: &str) -> String {
    s.trim().trim_start_matches(':').trim_matches('"').to_string()
}

fn conception_dir(script_path: &str) -> std::path::PathBuf {
    // Canonicalize so relative `capabilities/boot/boot.bluebook` invocations
    // produce absolute paths in the daemon command lines (otherwise the
    // detached spawn — which has no cwd guarantee — gets a relative path
    // like `/breath.sh` after substituting an empty conception dir).
    let abs = match std::fs::canonicalize(script_path) {
        Ok(p) => p,
        Err(_) => Path::new(script_path).to_path_buf(),
    };
    let mut cur = abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..5 {
        if cur.join("information").is_dir() && cur.join("capabilities").is_dir() {
            return cur;
        }
        if !cur.pop() { break; }
    }
    abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
}
