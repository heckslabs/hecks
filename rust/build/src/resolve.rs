//! Chapter resolution — the Rust equivalent of
//! `rust/project_rust_pipeline.rb`'s own `header_chapter_name`, framework
//! member lookup (`Hecksagain::Framework.members`), and the self-hosted
//! grammar's own nine-file list (`Hecksagain::Bluebook::MetaValidator::
//! GRAMMAR_FILES`). NONE of this executes a `.bluebook`/`.hecksagon`
//! file's own DSL body — every function here is plain text scanning or a
//! directory listing, the same "not a `Kernel.load`" distinction that
//! file's own header draws out at length.

use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::subprocess;

/// `header_chapter_name` (Ruby) — the declared chapter name off a
/// `.bluebook` file's own `Hecks.bluebook "Name"` header line, found by
/// PLAIN TEXT SCANNING (the same technique `spec/parser_parity_spec.rb::
/// chapter_name_of` and the Ruby pipeline this crate replaces both
/// already use) — never by parsing or executing the file.
pub fn header_chapter_name(path: &Path) -> Result<String, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("Hecks.bluebook") {
            if let Some(name) = extract_quoted(rest) {
                return Ok(name);
            }
        }
    }
    Err(format!("{} has no 'Hecks.bluebook \"Name\"' header", path.display()))
}

/// The first `"..."`-quoted substring after `Hecks.bluebook` on its own
/// line — matches Ruby's `/\A\s*Hecks\.bluebook\s+"([^"]+)"/` closely
/// enough for every real corpus header (whitespace before the opening
/// quote, no escapes inside a chapter name).
fn extract_quoted(rest: &str) -> Option<String> {
    let after_ws = rest.trim_start();
    if !after_ws.starts_with('"') {
        return None;
    }
    let inner = &after_ws[1..];
    let end = inner.find('"')?;
    Some(inner[..end].to_string())
}

/// `Hecksagain::Framework.members` (`lib/hecksagain/framework.rb`) — a
/// DIRECTORY LISTING, not a hand-kept list (that file's own header: "a
/// member added here and forgotten in a list would be a member
/// `uses_framework` could never find"). Named by file stem, pascal-cased
/// (`Naming.pascal`, `lib/hecksagain/naming.rb`), matching the one-to-one
/// spelling every framework member's own filename already keeps with its
/// declared chapter name.
pub fn framework_members(root: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    let dir = root.join("lib/hecksagain/framework/bluebook");
    let mut members = Vec::new();
    for entry in std::fs::read_dir(&dir).map_err(|e| format!("reading {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("reading {}: {e}", dir.display()))?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("bluebook") {
            continue;
        }
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
        members.push((pascal(&stem), path));
    }
    members.sort();
    Ok(members)
}

/// `Naming.pascal` (`lib/hecksagain/naming.rb`) — `snake_case` ->
/// `PascalCase`: split on `_`, upcase each part's first character, join.
pub fn pascal(text: &str) -> String {
    text.split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

/// `Hecksagain::Bluebook::MetaValidator::GRAMMAR_FILES`
/// (`lib/hecksagain/bluebook/meta_validator.rb`) — the self-hosted
/// language's own nine files, IN THIS DECLARED ORDER (not alphabetical —
/// merge order is significant, later files reference constructs earlier
/// ones declare). A literal mirror of a Ruby CONSTANT ARRAY, the same
/// category `rust/project_rust_pipeline.rb`'s own header names as
/// legitimate plain-data reading rather than DSL execution — this list
/// changes only when the self-hosted grammar itself gains or loses a
/// file, exactly as rarely as `keywords.rs` changes when `syntax.bluebook`
/// does, and carries the same obligation to stay in sync (unlike
/// `keywords.rs`, there is no generator for this one small, stable list
/// today — a mismatch would surface immediately as a parser byte-diff
/// against `spec/hecks_build_pipeline_spec.rb`'s own meta-chapter
/// comparison, not silently).
const GRAMMAR_FILE_STEMS: &[&str] = &["bluebook", "aggregate", "behavior", "shape", "entity", "reaction", "vocabulary", "syntax", "projection"];

pub fn grammar_files(root: &Path) -> Vec<PathBuf> {
    let dir = root.join("lib/hecksagain/language/bluebook");
    GRAMMAR_FILE_STEMS.iter().map(|stem| dir.join(format!("{stem}.bluebook"))).collect()
}

/// `hecks-parse resolve --chapter <Name> <hecksagon>`'s own
/// `uses_framework` list, shelled out to and parsed — never re-derived
/// by hand, matching the Ruby pipeline's own `resolved =
/// run_capture!(PARSER_BIN, "resolve", ...); JSON.parse(resolved).fetch
/// ("uses_framework")`.
pub fn resolve_uses_framework(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    let parser_bin_str = parser_bin.to_string_lossy().to_string();
    let hecksagon_str = hecksagon_path.to_string_lossy().to_string();
    let out = subprocess::run_capture(&parser_bin_str, &["resolve", "--chapter", chapter_name, &hecksagon_str])?;
    let json = Json::parse(&out).map_err(|e| format!("parsing 'hecks-parse resolve' output: {e}\n{out}"))?;
    let names = json.get("uses_framework").map(Json::each).unwrap_or(&[]);
    Ok(names.iter().filter_map(Json::as_str).map(str::to_string).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pascal_cases_snake_case_stems() {
        assert_eq!(pascal("governance"), "Governance");
        assert_eq!(pascal("console_settings"), "ConsoleSettings");
        assert_eq!(pascal("identity"), "Identity");
    }

    #[test]
    fn extracts_the_quoted_chapter_name() {
        assert_eq!(extract_quoted(r#" "Pizzas""#), Some("Pizzas".to_string()));
        assert_eq!(extract_quoted(r#" "Console Settings" do"#), Some("Console Settings".to_string()));
    }
}
