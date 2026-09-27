//! Finds the repo root by walking up from the current directory to `hecks.gemspec`.
//! Not `current_exe()`, which would tie the crate to its build output layout.

use std::path::{Path, PathBuf};

pub fn find() -> Result<PathBuf, String> {
    let start = std::env::current_dir().map_err(|e| format!("reading current directory: {e}"))?;
    find_from(&start)
}

fn find_from(start: &Path) -> Result<PathBuf, String> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join("hecks.gemspec").is_file() {
            return Ok(dir);
        }
        if !dir.pop() {
            return Err(format!(
                "could not find the hecks repo root (no 'hecks.gemspec' found walking up from {}) — \
                 run hecks-build from inside the repo",
                start.display()
            ));
        }
    }
}
