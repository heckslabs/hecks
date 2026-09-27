//! Subprocess helpers: run a command, check its exit status, surface stderr on failure.
//! The crate reaches `hecks-parse`, `hecks-codegen` and `cargo` only through these.

use std::path::Path;
use std::process::{Command, Stdio};

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

pub fn run(program: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(program).args(args).status().map_err(|e| format!("running {program} {}: {e}", args.join(" ")))?;
    if !status.success() {
        return Err(format!("{program} {} failed", args.join(" ")));
    }
    Ok(())
}

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
