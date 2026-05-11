//! Worker-WASM embedded-bluebooks emitter — i528 step 10, the fourth
//! member of the `:codegen` adapter family declared in
//! command_bus.hecksagon.
//!
//! [antibody-exempt: rust/src/specializer/embedded_bluebooks.rs —
//!  kernel-floor codegen emitter. Walks a project's bluebook tree
//!  and emits one Rust source — <app>/worker/src/embedded.rs — that
//!  compiles the bluebooks into the deployed Worker WASM as a
//!  static `&[(&str, &str)]` slice. Sibling to wasm_worker (the
//!  Worker the slice lives inside), cf_function_proxy (the Pages
//!  Function in front of the Worker), and ruby_command_class (the
//!  Ruby call-site emitter for the same bus). Retires the
//!  orphaned worker/scripts/regenerate-embedded.py the existing
//!  bin-buddy embedded.rs header still points at. Shape declared
//!  in codegen/embedded_bluebooks_shape/. Retires under i78 once
//!  the codegen meta-shape itself becomes bluebook-generated.]
//!
//! The emitted file is small in concept — a header comment, two
//! consts, and one big slice literal — but large in bytes :
//! bin-buddy's tree weighs ~4200 lines. Determinism matters more
//! than density : same inputs → same bytes.

use std::fs;
use std::path::{Path, PathBuf};

const SKIP_DIRS: &[&str] = &["target", "node_modules", ".git", "build", ".wrangler"];
const DEFAULT_HASH_COUNT: usize = 5;

/// Render `<app>/worker/src/embedded.rs` as a Rust source string.
///
/// `walk_root` is the absolute path to the project root to walk
/// for bluebook files. `app` is the kebab-case project folder ;
/// `primary_basename` is the entry-point bluebook's basename ;
/// `extensions` is the list of extensions (no dot) to embed.
///
/// Paths are recorded forward-slash and relative to `walk_root`.
/// Files are sorted alphabetically by relative path. Each tuple's
/// content is wrapped in a Rust raw-string ; hash count starts at
/// five and bumps if any file would close the raw-string early.
pub fn emit_embedded_rs(
    walk_root: &Path,
    app: &str,
    primary_basename: &str,
    extensions: &[&str],
) -> String {
    let mut files: Vec<(String, String)> = Vec::new();
    collect(walk_root, walk_root, extensions, &mut files);
    files.sort_by(|a, b| a.0.cmp(&b.0));
    render(app, primary_basename, &files)
}

/// Recursive collector. Pushes (relative-path, contents) for every
/// file under `dir` whose extension is in `extensions`. Skips the
/// directories named in `SKIP_DIRS`.
fn collect(root: &Path, dir: &Path, extensions: &[&str], out: &mut Vec<(String, String)>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    let mut sorted: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    sorted.sort();
    for path in sorted {
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_str()) || name.starts_with('.') && name != ".wrangler" {
                if !SKIP_DIRS.contains(&name.as_str()) {
                    // Hidden directory (starts with '.') that isn't an
                    // explicit skip — still walk only if it's not a
                    // dotfile dir. Bin-buddy keeps its tree visible ;
                    // hidden dirs are tooling debris we don't embed.
                    continue;
                }
                continue;
            }
            collect(root, &path, extensions, out);
        } else if path.is_file() {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or_default();
            if !extensions.contains(&ext) {
                continue;
            }
            let rel = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            let contents = match fs::read_to_string(&path) {
                Ok(c) => c,
                Err(_) => continue,
            };
            out.push((rel, contents));
        }
    }
}

/// Build the embedded.rs source from collected (path, contents)
/// rows. Mirrors the existing bin-buddy file byte-for-byte : two
/// consts, one slice literal, four-space indent per tuple.
fn render(app: &str, primary_basename: &str, files: &[(String, String)]) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "// AUTO-GENERATED — {app} bluebooks embedded into the Worker WASM.\n\
         // To regenerate (until `hecks-life compile` ships per inbox/i103) :\n\
         //   python3 worker/scripts/regenerate-embedded.py\n\
         //\n\
         // Embedded files : {count}\n\
         // Primary        : {primary}\n\
         \n\
         pub const PRIMARY_BASENAME: &str = \"{primary}\";\n\
         pub const BLUEBOOK_COUNT:   usize = {count};\n\
         \n\
         pub static EMBEDDED_BLUEBOOKS: &[(&str, &str)] = &[\n",
        app = app,
        count = files.len(),
        primary = primary_basename,
    ));
    for (path, contents) in files {
        let n = hash_count_for(contents);
        let hashes = "#".repeat(n);
        s.push_str(&format!(
            "    (\"{path}\", r{h}\"{contents}\"{h}),\n",
            path = path,
            h = hashes,
            contents = contents,
        ));
    }
    s.push_str("];\n");
    s
}

/// Pick the smallest hash count N such that a Rust raw-string of
/// the form `r{N hashes}"..."{N hashes}` doesn't close early on
/// the given content. Starts at five (matches the existing
/// bin-buddy file ; empirically enough), bumps to N+1 only if the
/// content contains `"#####...`.
fn hash_count_for(content: &str) -> usize {
    let mut n = DEFAULT_HASH_COUNT;
    loop {
        let closer = format!("\"{}", "#".repeat(n));
        if !content.contains(&closer) {
            return n;
        }
        n += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn bin_buddy_root() -> PathBuf {
        PathBuf::from("/Users/christopheryoung/Projects/bin-buddy")
    }

    #[test]
    fn header_records_app_name_and_primary() {
        let rs = emit_embedded_rs(
            &bin_buddy_root(),
            "bin-buddy",
            "bin-buddy.bluebook",
            &["bluebook", "hecksagon", "world", "fixtures"],
        );
        assert!(rs.starts_with("// AUTO-GENERATED — bin-buddy bluebooks embedded into the Worker WASM.\n"));
        assert!(rs.contains("pub const PRIMARY_BASENAME: &str = \"bin-buddy.bluebook\";"));
    }

    #[test]
    fn bluebook_count_matches_embedded_tuples() {
        let rs = emit_embedded_rs(
            &bin_buddy_root(),
            "bin-buddy",
            "bin-buddy.bluebook",
            &["bluebook", "hecksagon", "world", "fixtures"],
        );
        let tuple_count = rs.matches("\n    (\"").count();
        let recorded: usize = rs
            .lines()
            .find_map(|l| l.strip_prefix("pub const BLUEBOOK_COUNT:   usize = "))
            .and_then(|l| l.trim_end_matches(';').parse().ok())
            .unwrap();
        assert_eq!(tuple_count, recorded);
    }

    #[test]
    fn entries_sorted_alphabetically_by_relative_path() {
        let rs = emit_embedded_rs(
            &bin_buddy_root(),
            "bin-buddy",
            "bin-buddy.bluebook",
            &["bluebook", "hecksagon", "world", "fixtures"],
        );
        let paths: Vec<&str> = rs
            .lines()
            .filter_map(|l| l.strip_prefix("    (\""))
            .filter_map(|l| l.split("\",").next())
            .collect();
        let mut sorted = paths.clone();
        sorted.sort();
        assert_eq!(paths, sorted);
    }

    #[test]
    fn hash_count_avoids_collisions() {
        assert_eq!(hash_count_for("plain content"), 5);
        let with_five = "boom \"##### inside";
        assert!(hash_count_for(with_five) >= 6);
    }

    #[test]
    fn dump_bin_buddy_embedded_to_tmp() {
        let rs = emit_embedded_rs(
            &bin_buddy_root(),
            "bin-buddy",
            "bin-buddy.bluebook",
            &["bluebook", "hecksagon", "world", "fixtures"],
        );
        let _ = std::fs::write("/tmp/binbuddy_embedded_rs.txt", &rs);
    }
}
