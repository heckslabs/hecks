//! Subprocess helpers — the Rust equivalent of
//! `rust/project_rust_pipeline.rb`'s own `run_capture!`/`run!`/`build!`
//! (`Open3.capture3`/`system`), unchanged in spirit: shell out, check the
//! exit status, surface stderr on failure. This is the crate's ONLY way
//! of talking to `hecks-parse`/`hecks-codegen`/`cargo` — see this crate's
//! own main.rs header for why subprocess, not a library dependency, is
//! the deliberate architecture here.

use std::path::Path;
use std::process::{Command, Stdio};

/// `run_capture!` (Ruby) — run a command, return its stdout as text.
/// Non-zero exit is an error carrying stderr, exactly like Ruby's own
/// `Open3.capture3` + `status.success? or abort` pair.
pub fn run_capture(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program).args(args).output().map_err(|e| format!("running {program} {}: {e}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "{program} {} failed:\n{}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    String::from_utf8(output.stdout).map_err(|e| format!("{program} {}: stdout was not valid UTF-8: {e}", args.join(" ")))
}

/// `run!` (Ruby) — run a command, streaming its own stdout/stderr through
/// to ours (matching Ruby's bare `system(*cmd)`, which inherits the
/// parent's own file descriptors), erroring on a non-zero exit.
pub fn run(program: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(program).args(args).status().map_err(|e| format!("running {program} {}: {e}", args.join(" ")))?;
    if !status.success() {
        return Err(format!("{program} {} failed", args.join(" ")));
    }
    Ok(())
}

/// `run!` with a working directory — `cargo build`'s own two real call
/// sites (building `hecks-parse`/`hecks-codegen` themselves, and later
/// the domain's own compiled artifact) both need `chdir:`, matching
/// Ruby's `system(..., chdir: crate_dir, ...)`.
pub fn run_in(dir: &Path, program: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(program)
        .args(args)
        .current_dir(dir)
        .status()
        .map_err(|e| format!("running {program} {} in {}: {e}", args.join(" "), dir.display()))?;
    if !status.success() {
        return Err(format!("{program} {} failed in {}", args.join(" "), dir.display()));
    }
    Ok(())
}

/// `build!` (Ruby) — `cargo build` in a crate directory, output
/// suppressed only when the caller explicitly wants a quiet check (never
/// used for the domain's own real build, which streams through
/// unchanged so a real failure is visible immediately).
pub fn cargo_build_quiet(dir: &Path) -> Result<(), String> {
    let status = Command::new("cargo")
        .arg("build")
        .current_dir(dir)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| format!("running cargo build in {}: {e}", dir.display()))?;
    if !status.success() {
        return Err(format!("cargo build failed in {} — run it there directly to see why", dir.display()));
    }
    Ok(())
}
