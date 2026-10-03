//! Chapter resolution: header names, framework members and vendored packages, found by text
//! scanning and directory listing rather than by executing any DSL.

use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::subprocess;

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

// Plain text scan of the `Hecks.bluebook "Name"` line; the file is never executed.
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

fn extract_quoted(rest: &str) -> Option<String> {
    let after_ws = rest.trim_start();
    if !after_ws.starts_with('"') {
        return None;
    }
    let inner = &after_ws[1..];
    let end = inner.find('"')?;
    Some(inner[..end].to_string())
}

// A directory listing, so a member is never missing from a hand-kept list.
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

// Discovery, not a mirrored filename list, so a new concept cannot drift from this pipeline.
pub fn grammar_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    let dir = root.join("lib/hecks/language/bluebook");
    bluebook_files(&dir)
}

// The names `attaches "Name"` gave, for a chapter the gem carries.
pub fn resolve_gem_chapters(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    resolve_json(parser_bin, chapter_name, hecksagon_path, "gem_chapters")
}

// The names `attaches "name", from: :vendor` gave, for a vendored package.
pub fn resolve_vendored_packages(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    resolve_json(parser_bin, chapter_name, hecksagon_path, "vendored_packages")
}

// Where the gem keeps the chapters other than framework members, relative to `lib/hecks`; the
// same places `Hecks::Chapters::GLOBS` lists.
const OTHER_GEM_CHAPTER_DIRS: &[&str] = &["language", "grammar", "tenancy/bluebook", "deploy/bluebook", "quality_control"];

// The names of the chapters the gem carries beside the framework members, found by reading each
// file's header. Only the Ruby runtime loads them, so the build uses this list to tell a real
// gem chapter from a misspelt name.
pub fn other_gem_chapter_names(root: &Path) -> Result<Vec<String>, String> {
    fn walk(directory: &Path, names: &mut Vec<String>) -> Result<(), String> {
        let Ok(entries) = std::fs::read_dir(directory) else { return Ok(()) };
        for entry in entries {
            let path = entry.map_err(|e| format!("reading {}: {e}", directory.display()))?.path();
            if path.is_dir() {
                walk(&path, names)?;
            } else if path.extension().and_then(|e| e.to_str()) == Some("bluebook") {
                if let Ok(name) = header_chapter_name(&path) {
                    names.push(name);
                }
            }
        }
        Ok(())
    }
    let mut names = Vec::new();
    for directory in OTHER_GEM_CHAPTER_DIRS {
        walk(&root.join("lib/hecks").join(directory), &mut names)?;
    }
    names.sort();
    names.dedup();
    Ok(names)
}

fn resolve_json(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path, key: &str) -> Result<Vec<String>, String> {
    let parser_bin_str = parser_bin.to_string_lossy().to_string();
    let hecksagon_str = hecksagon_path.to_string_lossy().to_string();
    let out = subprocess::run_capture(&parser_bin_str, &["resolve", "--chapter", chapter_name, &hecksagon_str])?;
    let json = Json::parse(&out).map_err(|e| format!("parsing 'hecks-parse resolve' output: {e}\n{out}"))?;
    let names = json.get(key).map(Json::each).unwrap_or(&[]);
    Ok(names.iter().filter_map(Json::as_str).map(str::to_string).collect())
}

/// `/\A[a-z][a-z0-9_]*\z/` — the shape `hecks vendor` accepts for a package directory name.
/// The name is joined into a path and, through its chapter, into a directory the build deletes,
/// so `../x` or an absolute path must never reach either.
pub fn valid_package_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase()) && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

pub fn vendored_bluebook_files(domain: &Path, pkg_name: &str) -> Result<Vec<PathBuf>, String> {
    if !valid_package_name(pkg_name) {
        return Err(format!(
            "attaches {pkg_name:?}, from: :vendor is not a package name — it must match [a-z][a-z0-9_]* (the name `hecks vendor` accepts)"
        ));
    }
    let dir = domain.join("vendor").join("embryonaut_bluebooks").join(pkg_name).join("bluebook");
    if !dir.is_dir() {
        return Err(format!(
            "attaches {pkg_name:?}, from: :vendor names no vendored bluebook at {} — run hecks vendor {pkg_name}",
            dir.display()
        ));
    }
    bluebook_files(&dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_package_name_that_is_a_path_is_refused_before_any_directory_is_touched() {
        for name in ["../x", "a/b", "/etc", "", "X", "1st", "a-b", "a b", ".."] {
            assert!(!valid_package_name(name), "{name:?}");
            let refusal = vendored_bluebook_files(Path::new("/nonexistent"), name).unwrap_err();
            assert!(refusal.contains("is not a package name"), "{refusal}");
        }
        for name in ["payments", "console_settings", "a1"] {
            assert!(valid_package_name(name), "{name:?}");
        }
    }

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
