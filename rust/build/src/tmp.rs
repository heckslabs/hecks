//! A minimal, dependency-free RAII temp directory — `Dir.mktmpdir`'s
//! Rust equivalent, hand-rolled rather than pulling in the `tempfile`
//! crate (this crate's own no-dependency discipline, matching
//! `rust/parser`'s and `rust/codegen`'s own Cargo.toml).

use std::path::{Path, PathBuf};

pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(prefix: &str) -> Result<Self, String> {
        let base = std::env::temp_dir();
        let pid = std::process::id();
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let path = base.join(format!("{prefix}-{pid}-{nanos}"));
        std::fs::create_dir_all(&path).map_err(|e| format!("creating temp dir {}: {e}", path.display()))?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
