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

pub fn resolve_uses_framework(parser_bin: &Path, chapter_name: &str, hecksagon_path: &Path) -> Result<Vec<String>, String> {
    resolve_json(parser_bin, chapter_name, hecksagon_path, "uses_framework")
}

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

pub fn vendored_bluebook_files(domain: &Path, pkg_name: &str) -> Result<Vec<PathBuf>, String> {
    let dir = domain.join("vendor").join("embryonaut_bluebooks").join(pkg_name).join("bluebook");
    if !dir.is_dir() {
        return Err(format!(
            "uses_embryonaut_bluebook {pkg_name:?} names no vendored bluebook at {} — run hecks vendor {pkg_name}",
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
