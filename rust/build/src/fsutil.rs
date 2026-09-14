//! `RustProjection::WriteIfChanged` (`rust/project/write_if_changed.rb`),
//! ported — the reason `bin/project_rust` never rewrote a byte-identical
//! generated file: a rewritten file's mtime changes regardless of content,
//! and Cargo rebuilds everything downstream on mtime alone (measured on the
//! Ruby side: a content-identical second wasm build cost the same ~45-49s as
//! the first). Since ADR 0054a's B3 `bin/project_rust` generates through
//! this crate by default, so the same discipline has to live here too.
//!
//! Two pieces: `write_if_changed` (skip a no-op write) and `sync_dir`
//! (regenerate-in-place-then-prune — the Ruby `track_directory`'s own
//! "a file nothing regenerated this run is gone, a file merely unchanged
//! keeps its mtime" contract, applied by generating into a scratch
//! directory first and copying across only what differs).

use std::collections::BTreeSet;
use std::path::Path;

/// Writes `content` to `path` unless the file already holds exactly those
/// bytes. Answers whether it actually wrote.
pub fn write_if_changed(path: &Path, content: &[u8]) -> Result<bool, String> {
    if let Ok(existing) = std::fs::read(path) {
        if existing == content {
            return Ok(false);
        }
    }
    std::fs::write(path, content).map_err(|e| format!("writing {}: {e}", path.display()))?;
    Ok(true)
}

/// Makes `dst` hold exactly `src`'s files: each file copied only when its
/// bytes differ, and every entry already in `dst` that `src` doesn't have
/// (a file for a construct no longer declared, or a stray directory)
/// removed — `pop_and_prune`'s own orphan rule. Generated module
/// directories are flat, so `src` is read one level deep.
pub fn sync_dir(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| format!("creating {}: {e}", dst.display()))?;

    let mut generated = BTreeSet::new();
    for entry in read_dir_sorted(src)? {
        let name = entry.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let content = std::fs::read(&entry).map_err(|e| format!("reading {}: {e}", entry.display()))?;
        let target = dst.join(&name);
        let wrote = write_if_changed(&target, &content)?;
        println!("{} {}", if wrote { "wrote" } else { "unchanged" }, target.display());
        generated.insert(name);
    }

    for entry in read_dir_sorted(dst)? {
        let name = entry.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if generated.contains(&name) {
            continue;
        }
        let removed = if entry.is_dir() { std::fs::remove_dir_all(&entry) } else { std::fs::remove_file(&entry) };
        removed.map_err(|e| format!("removing {}: {e}", entry.display()))?;
        println!("pruned {} (no longer generated)", entry.display());
    }
    Ok(())
}

fn read_dir_sorted(dir: &Path) -> Result<Vec<std::path::PathBuf>, String> {
    let mut paths = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(|e| format!("reading {}: {e}", dir.display()))? {
        paths.push(entry.map_err(|e| format!("reading {}: {e}", dir.display()))?.path());
    }
    paths.sort();
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tmp::TempDir;

    #[test]
    fn skips_an_identical_write_and_writes_a_different_one() {
        let tmp = TempDir::new("fsutil-write").unwrap();
        let path = tmp.path().join("a.rs");
        assert!(write_if_changed(&path, b"one").unwrap());
        assert!(!write_if_changed(&path, b"one").unwrap());
        assert!(write_if_changed(&path, b"two").unwrap());
        assert_eq!(std::fs::read(&path).unwrap(), b"two");
    }

    #[test]
    fn sync_copies_changed_files_and_prunes_orphans() {
        let tmp = TempDir::new("fsutil-sync").unwrap();
        let src = tmp.path().join("src");
        let dst = tmp.path().join("dst");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::create_dir_all(dst.join("stale_dir")).unwrap();
        std::fs::write(src.join("keep.rs"), "new").unwrap();
        std::fs::write(dst.join("keep.rs"), "old").unwrap();
        std::fs::write(dst.join("gone.rs"), "orphan").unwrap();

        sync_dir(&src, &dst).unwrap();

        assert_eq!(std::fs::read_to_string(dst.join("keep.rs")).unwrap(), "new");
        assert!(!dst.join("gone.rs").exists());
        assert!(!dst.join("stale_dir").exists());
    }
}
