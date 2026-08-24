//! Locating the repo root — the one piece of bookkeeping
//! `rust/project_rust_pipeline.rb` gets for free (`ROOT = File.expand_path
//! ("..", __dir__)`, resolved off the SCRIPT'S OWN file path, independent
//! of whatever directory it was invoked from) that a compiled binary has
//! to do differently: `std::env::current_exe()` would tie this crate to
//! its own build output layout (`rust/build/target/{debug,release}/
//! hecks-build`), fragile the moment that layout changes for any reason
//! unrelated to this crate's own logic. Walking up from the CURRENT
//! DIRECTORY looking for `hecks.gemspec` (a file that names the repo
//! root unambiguously and never moves) is the same technique `bundle
//! exec`/`rspec`/`cargo` themselves already rely on for "find my project
//! root from wherever the user happens to be standing" — robust to being
//! invoked from the repo root OR from any subdirectory beneath it.

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
