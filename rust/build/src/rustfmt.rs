//! Lays generated Rust out with rustfmt, as `Hecks::RustFormat` does for `hecks project_rust`, so
//! the tree `hecks-build` writes matches the one `hecks project_rust` writes, byte for byte.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const EDITION: &str = "2021";

// The most passes made; a text still changing after them keeps the last result, as in Ruby.
const PASSES: usize = 3;

/// Formats every `.rs` file of this run's own output: the `mod.rs` at `out_root` and each of
/// `dirs` beneath it, skipping a directory that is not there. A file is rewritten only when its
/// layout changes, so mtimes stay put and Cargo does not rebuild what did not change.
pub fn format_generated(out_root: &Path, dirs: &[String]) -> Result<(), String> {
    let mut files = vec![out_root.join("mod.rs")];
    for dir in dirs {
        collect_rust_files(&out_root.join(dir), &mut files)?;
    }
    for file in files.iter().filter(|f| f.is_file()) {
        format_file(file)?;
    }
    Ok(())
}

fn collect_rust_files(dir: &Path, into: &mut Vec<PathBuf>) -> Result<(), String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Ok(());
    };
    let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for path in paths {
        if path.is_dir() {
            collect_rust_files(&path, into)?;
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            into.push(path);
        }
    }
    Ok(())
}

fn format_file(path: &Path) -> Result<(), String> {
    let text =
        std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let formatted = format_source(&text)?;
    if formatted != text {
        std::fs::write(path, formatted).map_err(|e| format!("writing {}: {e}", path.display()))?;
    }
    Ok(())
}

fn format_source(text: &str) -> Result<String, String> {
    let mut current = text.to_string();
    for _ in 0..PASSES {
        let formatted = pass(&current)?;
        if formatted == current {
            break;
        }
        current = formatted;
    }
    Ok(current)
}

// One rustfmt run over stdin. Text rustfmt cannot parse is returned as it came, with a warning:
// the compiler will name the real fault.
fn pass(text: &str) -> Result<String, String> {
    let mut child = Command::new("rustfmt")
        .args(["--edition", EDITION, "--emit", "stdout"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            format!("running rustfmt: {e} (generated Rust is formatted with it; run `rustup component add rustfmt`)")
        })?;
    let mut stdin = child.stdin.take().ok_or("rustfmt gave no stdin")?;
    let input = text.to_string();
    // Written from a thread: a large file fills the pipe before rustfmt starts reading its output.
    let writer = std::thread::spawn(move || stdin.write_all(input.as_bytes()));
    let output = child
        .wait_with_output()
        .map_err(|e| format!("waiting for rustfmt: {e}"))?;
    let _ = writer.join();
    if output.status.success() {
        return String::from_utf8(output.stdout)
            .map_err(|e| format!("rustfmt output was not UTF-8: {e}"));
    }
    let first = String::from_utf8_lossy(&output.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_string();
    eprintln!(
        "hecks-build: rustfmt could not format generated Rust, leaving it as generated: {first}"
    );
    Ok(text.to_string())
}
