//! Maps the first error from `hecks-parse chapter` on a buffer to an LSP diagnostic.
//! The parser reports a file and line only, so a diagnostic covers the whole line.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The parser's refusal of a buffer, in the terms an editor needs.
pub struct FileDiagnostic {
    pub line: usize, // 1-indexed
    /// The 1-indexed character column the problem starts at; `None` when the parser refused
    /// the line as a whole, as it does for every file in the Ruby form.
    pub column: Option<usize>,
    pub message: String,
    pub expected: Vec<String>,
    /// True when the grammar admits the construct but the parser does not build it yet.
    pub not_yet_implemented: bool,
}

/// Runs `hecks-parse chapter` on the file at `path` and returns at most one diagnostic.
///
/// `Ok(None)` means the parse succeeded or the buffer declares no bluebook.
/// Runs the parser as a subprocess because `rust/parser` ships only a binary target.
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
        return Ok(None);
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

/// Finds the name in the first `Hecks.bluebook "Name"` or `Hecks.hecksagon "Name"` line, or in
/// the `Domain: name` line of a file written as sentences, whose words are capitalised and joined.
/// Hand-scanned because this crate takes no dependencies.
pub fn chapter_name(text: &str) -> Option<String> {
    for line in text.lines() {
        if let Some(after) = line.trim_start().strip_prefix("Domain:") {
            let name: String = after
                .split_whitespace()
                .map(|word| {
                    let mut chars = word.chars();
                    chars.next().map_or_else(String::new, |first| {
                        first.to_uppercase().collect::<String>() + chars.as_str()
                    })
                })
                .collect();
            if !name.is_empty() {
                return Some(name);
            }
        }
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

/// Parses `<file>:<line>: <message>` with an optional `(expected one of: a, b, c)` suffix.
// `path` is stripped as a known prefix so a colon inside the message cannot confuse the split.
fn parse_diagnostic_line(line: &str, path: &Path) -> Option<FileDiagnostic> {
    let prefix = format!("{}:", path.display());
    let rest = line.strip_prefix(&prefix)?;
    let (line_no, rest) = rest.split_once(':')?;
    let line_no: usize = line_no.trim().parse().ok()?;
    // A file written as sentences also names the column: `<file>:<line>:<column>: <message>`.
    let (column, rest) = match rest.split_once(':') {
        Some((digits, after))
            if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) =>
        {
            (digits.parse().ok(), after)
        }
        _ => (None, rest),
    };
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
        column,
        not_yet_implemented: message.starts_with("not yet implemented:"),
        message,
        expected,
    })
}

/// Finds `hecks-parse`: `HECKS_PARSE_BIN`, then `PATH`, then `../parser/target/{debug,release}`.
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

/// Walks `PATH` for a file named `name`.
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
    fn finds_a_sentence_file_chapter_name_from_its_domain_line() {
        assert_eq!(
            chapter_name("Domain: customer orders\n"),
            Some("CustomerOrders".to_string())
        );
    }

    #[test]
    fn reads_the_column_a_sentence_refusal_names() {
        let path = Path::new("/tmp/page.bluebook");
        let line = "/tmp/page.bluebook:11:5: this is not a sentence I know in a value object: \"Rull x\" (expected one of: Rule <description> holds when <condition>)";
        let diag = parse_diagnostic_line(line, path).expect("parses");
        assert_eq!((diag.line, diag.column), (11, Some(5)));
        assert!(diag.message.starts_with("this is not a sentence I know"));
        assert_eq!(
            diag.expected,
            vec!["Rule <description> holds when <condition>"]
        );
    }

    #[test]
    fn a_whole_line_refusal_has_no_column() {
        let path = Path::new("/tmp/pizzas.bluebook");
        let line = "/tmp/pizzas.bluebook:12: unknown word 'topping' in Aggregate";
        assert_eq!(
            parse_diagnostic_line(line, path).expect("parses").column,
            None
        );
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
