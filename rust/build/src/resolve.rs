//! Chapter resolution — the Rust equivalent of
//! `rust/project_rust_pipeline.rb`'s own `header_chapter_name`, framework
//! member lookup (`Hecks::Framework.members`), and the self-hosted
//! grammar's own nine-file list (`Hecks::Bluebook::MetaValidator::
//! GRAMMAR_FILES`). None of this executes a `.bluebook`/`.hecksagon`
//! file's own DSL body — every function here is plain text scanning or a
//! directory listing, the same "not a `Kernel.load`" distinction that
//! file's own header draws out at length.

use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::subprocess;

/// Every `.bluebook` directly in a domain's bluebook folder, sorted. The
/// folder is the source unit; adding a business-concept file never requires a
/// manifest or a filename convention.
pub fn bluebook_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).map_err(|e| format!("reading {}: {e}", directory.display()))? {
        let path = entry.map_err(|e| format!("reading {}: {e}", directory.display()))?.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("bluebook") {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

/// `header_chapter_name` (Ruby) — the declared chapter name off a
/// `.bluebook` file's own `Hecks.bluebook "Name"` header line, found by
/// plain text scanning (the same technique `spec/parser_parity_spec.rb::
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

/// `Hecks::Framework.members` (`lib/hecks/framework.rb`) — a
/// directory listing, not a hand-kept list (that file's own header: "a
/// member added here and forgotten in a list would be a member
/// `uses_framework` could never find"). Named by file stem, pascal-cased
/// (`Naming.pascal`, `lib/hecks/naming.rb`), matching the one-to-one
/// spelling every framework member's own filename already keeps with its
/// declared chapter name.
pub fn framework_members(root: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    let dir = root.join("lib/hecks/framework/bluebook");
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

/// `Naming.pascal` (`lib/hecks/naming.rb`) — `snake_case` ->
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

/// The self-hosted Bluebook language follows the same folder-is-the-chapter
/// rule as ordinary domains. Discovery—not a mirrored Ruby filename array—is
/// the contract, so adding a domain concept cannot drift this native pipeline.
pub fn grammar_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    let dir = root.join("lib/hecks/language/bluebook");
    bluebook_files(&dir)
}

/// `hecks-parse resolve --chapter <Name> <hecksagon>`'s own
/// `uses_framework` list, shelled out to and parsed — never re-derived
/// by hand, matching the Ruby pipeline's own `resolved =
/// run_capture!(PARSER_BIN, "resolve", ...); JSON.parse(resolved).fetch
/// ("uses_framework")`.
pub fn resolve_uses_framework(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    resolve_json(parser_bin, chapter_name, hecksagon_path, "uses_framework")
}

/// The `uses_embryonaut_bluebook` twin of `resolve_uses_framework` —
/// same subprocess call, same output, a different key. `hecks-parse
/// resolve` already emits both keys in one call (`rust/parser/src/parse/
/// hecksagon.rs`); without this function reading the second one, a
/// vendored chapter would silently never reach `pipeline.rs`'s own
/// `chapters` — the exact gap `rust/project_rust_pipeline.rb`'s own
/// `uses_embryonaut_bluebook_names` fetch closed on the Ruby opt-in
/// pipeline (docs/decisions/0058).
pub fn resolve_uses_embryonaut_bluebook(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    resolve_json(parser_bin, chapter_name, hecksagon_path, "uses_embryonaut_bluebook")
}

fn resolve_json(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path, key: &str) -> Result<Vec<String>, String> {
    let parser_bin_str = parser_bin.to_string_lossy().to_string();
    let hecksagon_str = hecksagon_path.to_string_lossy().to_string();
    let out = subprocess::run_capture(&parser_bin_str, &["resolve", "--chapter", chapter_name, &hecksagon_str])?;
    let json = Json::parse(&out).map_err(|e| format!("parsing 'hecks-parse resolve' output: {e}\n{out}"))?;
    let names = json.get(key).map(Json::each).unwrap_or(&[]);
    Ok(names.iter().filter_map(Json::as_str).map(str::to_string).collect())
}

/// Every `.bluebook` directly under a vendored package's own
/// `<domain>/vendor/embryonaut_bluebooks/<name>/bluebook/`, sorted — the
/// same resolution `lib/hecks/embryonaut_bluebook.rb`'s own
/// `EmbryonautBluebook.load!` uses and `rust/project_rust_pipeline.rb`'s
/// own opt-in Ruby pipeline mirrors; a vendored package has no
/// `.hecksagon` of its own (same restriction `framework_members` draws),
/// just its `.bluebook` file(s).
pub fn vendored_bluebook_files(domain: &Path, pkg_name: &str) -> Result<Vec<PathBuf>, String> {
    let dir = domain.join("vendor").join("embryonaut_bluebooks").join(pkg_name).join("bluebook");
    if !dir.is_dir() {
        return Err(format!(
            "uses_embryonaut_bluebook {pkg_name:?} names no vendored bluebook at {} — run bin/vendor_embryonaut_bluebooks {pkg_name}",
            dir.display()
        ));
    }
    bluebook_files(&dir)
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
