//! Bridges one open `.bluebook`/`.hecksagon` buffer to `hecks-parse` and
//! back to an LSP `Diagnostic` array.
//!
//! DELIBERATELY A SUBPROCESS, NOT A LIBRARY CALL: `rust/parser` ships
//! only a `[[bin]]` target, on purpose (its own Cargo.toml: "this crate
//! reads bytes and writes JSON text by hand ... no dependency earns its
//! way past std", and its own workspace-isolation comment rules out
//! being folded into a shared lib). Restructuring it into a lib crate
//! this one could link was avoided the same way `rust/build/src/json.rs`
//! already avoided it for a different sibling — every one of these
//! crates stays a stable, subprocess-only sibling of `rust/parser`
//! rather than a thing that could accidentally start sharing (and so
//! coupling to) its internals. The real, load-bearing side effect: this
//! LSP's diagnostics get MORE ACCURATE for free as `hecks-parse` itself
//! grows past its current Stage — nothing here needs to change when a
//! stub in `rust/parser/src/parse/*.rs` becomes real.
//!
//! ONE DIAGNOSTIC PER RUN: `hecks-parse chapter` stops at the first
//! error (`parse::chapter`'s own doc comment: "Stops at the FIRST
//! diagnostic"), so this can only ever publish zero or one diagnostic
//! per document per run — a real limitation inherited from the parser's
//! own fail-fast design, not something this crate works around. Once
//! `rust/parser` collects multiple diagnostics per run, this module's
//! `run` only needs to map `Vec<Diagnostic>` instead of `Option<Diagnostic>`
//! — everything else here already speaks in terms of a list.
//!
//! NO COLUMN INFORMATION: `Diagnostic` (`rust/parser/src/diag.rs`) only
//! ever names a file and a LINE, never a column — so every diagnostic
//! this crate publishes underlines the FULL line, not a precise span.
//! Good enough for "something on this line is wrong, click through to
//! read why" (the message and `expected` list carry the real content);
//! real squiggle precision needs `rust/parser` to start tracking columns
//! first.

use std::path::{Path, PathBuf};
use std::process::Command;

pub struct FileDiagnostic {
    pub line: usize, // 1-indexed, straight from `Diagnostic::line`
    pub message: String,
    pub expected: Vec<String>,
    /// Distinguishes `Diagnostic::not_yet_implemented`'s own wording
    /// ("a real grammar admits this, the parser doesn't build it yet")
    /// from every other diagnostic ("the grammar doesn't admit this") —
    /// `diag.rs`'s own header draws exactly this line, and it's worth
    /// keeping visible in the editor as a Warning vs. an Error rather
    /// than flattening both to the same severity.
    pub not_yet_implemented: bool,
}

/// Runs `hecks-parse chapter --chapter <name> <path>` against whatever
/// is currently on disk at `path` and returns at most one diagnostic.
/// `Ok(None)` means either the parse succeeded or no chapter name could
/// be found in the buffer at all (nothing to report either way — see
/// `chapter_name`'s own doc comment).
pub fn run(hecks_parse: &Path, path: &Path, text: &str) -> Result<Option<FileDiagnostic>, String> {
    let Some(name) = chapter_name(text) else {
        return Ok(None);
    };

    let output = Command::new(hecks_parse)
        .arg("chapter")
        .arg("--chapter")
        .arg(&name)
        .arg(path)
        .output()
        .map_err(|e| format!("could not run {}: {e}", hecks_parse.display()))?;

    if output.status.success() {
        return Ok(None); // clean parse — caller publishes an empty list
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let Some(first_line) = stderr.lines().next() else {
        return Err(format!(
            "{} exited with {:?} and no stderr",
            hecks_parse.display(),
            output.status.code()
        ));
    };
    Ok(parse_diagnostic_line(first_line, path))
}

/// Finds the chapter this buffer declares, if any: the first
/// `Hecks.bluebook "Name"` or `Hecks.hecksagon "Name"` line — exactly
/// the string `hecks-parse chapter --chapter <Name>` itself requires
/// (`rust/parser/src/main.rs::run_chapter`), and the same header every
/// real `.bluebook`/`.hecksagon` file in the corpus opens with. A buffer
/// with neither (a brand-new empty file, a non-bluebook file the editor
/// happens to hand this server) has nothing to check yet, not an error.
///
/// Hand-scanned rather than regex — this crate takes no dependencies
/// (see its own Cargo.toml) and the shape is fixed and simple enough
/// that a small dependency-free scan reads as clearly as a pattern
/// would.
fn chapter_name(text: &str) -> Option<String> {
    for line in text.lines() {
        for needle in ["Hecks.bluebook \"", "Hecks.hecksagon \""] {
            if let Some(after) = line.trim_start().strip_prefix(needle) {
                if let Some(end) = after.find('"') {
                    return Some(after[..end].to_string());
                }
            }
        }
    }
    None
}

/// Parses one `Diagnostic::fmt`-formatted line (`diag.rs`):
/// `<file>:<line>: <message>` with an optional trailing
/// `(expected one of: a, b, c)`. `path` is the exact path this crate
/// itself passed to `hecks-parse` on the command line, so it's stripped
/// as a known prefix rather than re-derived — sidesteps any ambiguity
/// from a message that happens to contain a colon of its own.
fn parse_diagnostic_line(line: &str, path: &Path) -> Option<FileDiagnostic> {
    let prefix = format!("{}:", path.display());
    let rest = line.strip_prefix(&prefix)?;
    let (line_no, rest) = rest.split_once(':')?;
    let line_no: usize = line_no.trim().parse().ok()?;
    let rest = rest.strip_prefix(' ').unwrap_or(rest);

    let (message, expected) = match rest.rfind(" (expected one of: ") {
        Some(idx) if rest.ends_with(')') => {
            let message = &rest[..idx];
            let list = &rest[idx + " (expected one of: ".len()..rest.len() - 1];
            let expected = list.split(", ").map(str::to_string).collect();
            (message.to_string(), expected)
        }
        _ => (rest.to_string(), Vec::new()),
    };

    Some(FileDiagnostic {
        line: line_no,
        not_yet_implemented: message.starts_with("not yet implemented:"),
        message,
        expected,
    })
}

/// Where `hecks-parse` lives, checked in order: an explicit override
/// (for a checkout laid out differently, or CI), then PATH (once/if this
/// is ever `cargo install`'d), then the two paths a `cargo build`
/// (debug) or `cargo build --release` from `rust/parser/` actually
/// produces — the common case while both crates are developed side by
/// side out of this same checkout.
pub fn locate_hecks_parse() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("HECKS_PARSE_BIN") {
        let p = PathBuf::from(explicit);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Ok(path) = which("hecks-parse") {
        return Some(path);
    }
    for candidate in [
        "../parser/target/debug/hecks-parse",
        "../parser/target/release/hecks-parse",
    ] {
        let p = PathBuf::from(candidate);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// A tiny, dependency-free stand-in for the `which` crate: walks `PATH`
/// looking for an executable file named `name`. Good enough for the one
/// lookup this crate needs.
fn which(name: &str) -> Result<PathBuf, ()> {
    let path_var = std::env::var_os("PATH").ok_or(())?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Err(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_bluebook_chapter_name() {
        let text = "Hecks.bluebook \"Pizzas\" do\nend\n";
        assert_eq!(chapter_name(text), Some("Pizzas".to_string()));
    }

    #[test]
    fn finds_a_hecksagon_chapter_name_when_indented() {
        let text = "  Hecks.hecksagon \"Banking\" do\nend\n";
        assert_eq!(chapter_name(text), Some("Banking".to_string()));
    }

    #[test]
    fn no_chapter_name_is_not_an_error() {
        assert_eq!(chapter_name("# just a comment\n"), None);
    }

    #[test]
    fn parses_a_diagnostic_with_an_expected_list() {
        let path = Path::new("/tmp/pizzas.bluebook");
        let line = "/tmp/pizzas.bluebook:12: unknown word 'topping' in Aggregate (expected one of: attribute, command, query)";
        let diag = parse_diagnostic_line(line, path).expect("parses");
        assert_eq!(diag.line, 12);
        assert_eq!(diag.message, "unknown word 'topping' in Aggregate");
        assert_eq!(diag.expected, vec!["attribute", "command", "query"]);
        assert!(!diag.not_yet_implemented);
    }

    #[test]
    fn parses_a_not_yet_implemented_diagnostic_with_no_expected_list() {
        let path = Path::new("/tmp/pizzas.bluebook");
        let line = "/tmp/pizzas.bluebook:5: not yet implemented: Bluebook.report (Stage 1 — see spec/parser_coverage_spec.rb)";
        let diag = parse_diagnostic_line(line, path).expect("parses");
        assert_eq!(diag.line, 5);
        assert!(diag.expected.is_empty());
        assert!(diag.not_yet_implemented);
    }
}
