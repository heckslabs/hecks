//! Bluebook resolution: header names, framework members and vendored packages, found by text
//! scanning and directory listing rather than by executing any DSL.

use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::subprocess;

pub fn bluebook_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    for entry in
        std::fs::read_dir(directory).map_err(|e| format!("reading {}: {e}", directory.display()))?
    {
        let path = entry
            .map_err(|e| format!("reading {}: {e}", directory.display()))?
            .path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("bluebook") {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

// Plain text scan of the `Hecks.bluebook "Name"` line; the file is never executed.
pub fn header_bluebook_name(path: &Path) -> Result<String, String> {
    let text =
        std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("Hecks.bluebook") {
            if let Some(name) = extract_quoted(rest) {
                return Ok(name);
            }
        }
    }
    Err(format!(
        "{} has no 'Hecks.bluebook \"Name\"' header",
        path.display()
    ))
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
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        members.push((crate::hecks_naming::pascal(&stem), path));
    }
    members.sort();
    Ok(members)
}

// Discovery, not a mirrored filename list, so a new concept cannot drift from this pipeline.
pub fn grammar_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    let dir = root.join("lib/hecks/language/bluebook");
    bluebook_files(&dir)
}

// The names `attaches "Name"` gave, for a bluebook the gem carries.
pub fn resolve_gem_bluebooks(
    parser_bin: &Path,
    declaration_name: &str,
    hecksagon_path: &Path,
) -> Result<Vec<String>, String> {
    resolve_json(
        parser_bin,
        declaration_name,
        hecksagon_path,
        "gem_bluebooks",
    )
}

// The names `attaches "name", from: :vendor` gave, for a vendored package.
pub fn resolve_vendored_packages(
    parser_bin: &Path,
    declaration_name: &str,
    hecksagon_path: &Path,
) -> Result<Vec<String>, String> {
    resolve_json(
        parser_bin,
        declaration_name,
        hecksagon_path,
        "vendored_packages",
    )
}

/// Each attachment's name and the role its `acts_as:` names (ADR 0216).
pub fn resolve_attachment_roles(
    parser_bin: &Path,
    declaration_name: &str,
    hecksagon_path: &Path,
) -> Result<Vec<(String, String)>, String> {
    let json = resolve_output(parser_bin, declaration_name, hecksagon_path)?;
    let roles = match json.get("acts_as") {
        Some(Json::Object(pairs)) => pairs
            .iter()
            .filter_map(|(name, role)| role.as_str().map(|role| (name.clone(), role.to_string())))
            .collect(),
        _ => Vec::new(),
    };
    Ok(roles)
}

/// Gives each policy of an attached bluebook's IR that declares no `acts_as` the attachment's
/// role, placed after `root` as the parser places a declared one; `Attaching` does the same in Ruby.
pub fn acts_as_by_default(ir_text: &str, role: &str) -> Result<String, String> {
    let mut ir =
        Json::parse(ir_text).map_err(|e| format!("re-parsing ir.json for acts_as: {e}"))?;
    if let Some(Json::Array(policies)) = ir.get_mut("policies") {
        for policy in policies.iter_mut() {
            give_role(policy, role);
        }
    }
    Ok(crate::json::write(&ir))
}

// Sets one policy's `acts_as` to `role` unless it names one already.
fn give_role(policy: &mut Json, role: &str) {
    let Json::Object(pairs) = policy else {
        return;
    };
    if let Some((_, declared)) = pairs.iter_mut().find(|(key, _)| key == "acts_as") {
        if declared.as_str().is_none_or(str::is_empty) {
            *declared = Json::String(role.to_string());
        }
        return;
    }
    let at = pairs
        .iter()
        .position(|(key, _)| key == "root")
        .map_or(pairs.len(), |index| index + 1);
    pairs.insert(at, ("acts_as".to_string(), Json::String(role.to_string())));
}

// Where the gem keeps the bluebooks other than framework members, relative to `lib/hecks`; the
// same places `Hecks::Bluebooks::GLOBS` lists.
const OTHER_GEM_BLUEBOOK_DIRS: &[&str] = &[
    "language",
    "grammar",
    "tenancy/bluebook",
    "deploy/bluebook",
    "site/bluebook",
    "tickets/bluebook",
    "composer/bluebook",
    "quality_control",
    "bulk/bluebook",
    "ci_pipeline",
];

// Every bluebook the gem carries beside the framework members, with the bluebook its header names.
fn other_gem_bluebook_entries(root: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    fn walk(directory: &Path, entries: &mut Vec<(String, PathBuf)>) -> Result<(), String> {
        let Ok(listing) = std::fs::read_dir(directory) else {
            return Ok(());
        };
        for entry in listing {
            let path = entry
                .map_err(|e| format!("reading {}: {e}", directory.display()))?
                .path();
            if path.is_dir() {
                walk(&path, entries)?;
            } else if path.extension().and_then(|e| e.to_str()) == Some("bluebook") {
                if let Ok(name) = header_bluebook_name(&path) {
                    entries.push((name, path));
                }
            }
        }
        Ok(())
    }
    let mut entries = Vec::new();
    for directory in OTHER_GEM_BLUEBOOK_DIRS {
        walk(&root.join("lib/hecks").join(directory), &mut entries)?;
    }
    entries.sort();
    Ok(entries)
}

// The names of the bluebooks the gem carries beside the framework members, found by reading each
// file's header, so the build tells a real gem bluebook from a misspelt name.
pub fn other_gem_bluebook_names(root: &Path) -> Result<Vec<String>, String> {
    let mut names: Vec<String> = other_gem_bluebook_entries(root)?
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    names.dedup();
    Ok(names)
}

// The files that declare one of the gem's other bluebooks, sorted, as `Hecks::Bluebooks` loads them,
// then the `<snake_name>.ports.hecksagon` beside them that declares the bluebook's ports.
pub fn other_gem_bluebook_files(root: &Path, declaration: &str) -> Result<Vec<PathBuf>, String> {
    let mut files: Vec<PathBuf> = other_gem_bluebook_entries(root)?
        .into_iter()
        .filter(|(name, _)| name == declaration)
        .map(|(_, path)| path)
        .collect();
    let ports = files
        .first()
        .and_then(|first| first.parent())
        .map(|directory| {
            directory.join(format!(
                "{}.ports.hecksagon",
                crate::hecks_naming::snake(declaration)
            ))
        });
    files.extend(ports.filter(|path| path.is_file()));
    Ok(files)
}

// Every `.hecksagon` beside a domain's bluebooks, sorted, as the registry loads them.
pub fn hecksagon_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let Ok(listing) = std::fs::read_dir(directory) else {
        return Ok(Vec::new());
    };
    let mut files = Vec::new();
    for entry in listing {
        let path = entry
            .map_err(|e| format!("reading {}: {e}", directory.display()))?
            .path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("hecksagon") {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

fn resolve_json(
    parser_bin: &Path,
    declaration_name: &str,
    hecksagon_path: &Path,
    key: &str,
) -> Result<Vec<String>, String> {
    let json = resolve_output(parser_bin, declaration_name, hecksagon_path)?;
    let names = json.get(key).map_or(&[][..], Json::each);
    Ok(names
        .iter()
        .filter_map(Json::as_str)
        .map(str::to_string)
        .collect())
}

// What `hecks-parse resolve` prints for one hecksagon block.
fn resolve_output(
    parser_bin: &Path,
    declaration_name: &str,
    hecksagon_path: &Path,
) -> Result<Json, String> {
    let parser_bin_str = parser_bin.to_string_lossy().to_string();
    let hecksagon_str = hecksagon_path.to_string_lossy().to_string();
    let out = subprocess::run_capture(
        &parser_bin_str,
        &["resolve", "--bluebook", declaration_name, &hecksagon_str],
    )?;
    Json::parse(&out).map_err(|e| format!("parsing 'hecks-parse resolve' output: {e}\n{out}"))
}

/// `/\A[a-z][a-z0-9_]*\z/` — the shape `hecks vendor` accepts for a package directory name.
/// The name is joined into a path and, through its bluebook, into a directory the build deletes,
/// so `../x` or an absolute path must never reach either.
pub fn valid_package_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

pub fn vendored_bluebook_files(domain: &Path, pkg_name: &str) -> Result<Vec<PathBuf>, String> {
    if !valid_package_name(pkg_name) {
        return Err(format!(
            "attaches {pkg_name:?}, from: :vendor is not a package name — it must match [a-z][a-z0-9_]* (the name `hecks vendor` accepts)"
        ));
    }
    let dir = domain
        .join("vendor")
        .join("embryonaut_bluebooks")
        .join(pkg_name)
        .join("bluebook");
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
        assert_eq!(crate::hecks_naming::pascal("governance"), "Governance");
        assert_eq!(
            crate::hecks_naming::pascal("console_settings"),
            "ConsoleSettings"
        );
        assert_eq!(crate::hecks_naming::pascal("identity"), "Identity");
    }

    #[test]
    fn extracts_the_quoted_bluebook_name() {
        assert_eq!(extract_quoted(r#" "Pizzas""#), Some("Pizzas".to_string()));
        assert_eq!(
            extract_quoted(r#" "Console Settings" do"#),
            Some("Console Settings".to_string())
        );
    }

    // A policy that declares no `acts_as` takes the attachment's role, after `root`.
    #[test]
    fn an_undeclared_policy_takes_the_attachments_role_after_root() {
        let ir = r#"{"policies":[{"name":"P","root":false,"where":null}]}"#;
        let given = Json::parse(&acts_as_by_default(ir, "System").unwrap()).unwrap();
        let policy = &given.get("policies").unwrap().each()[0];
        let Json::Object(pairs) = policy else {
            panic!("{policy:?}")
        };
        let keys: Vec<&str> = pairs.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(keys, ["name", "root", "acts_as", "where"]);
    }

    #[test]
    fn a_declared_acts_as_is_kept() {
        let ir = r#"{"policies":[{"name":"P","root":false,"acts_as":"Operator"}]}"#;
        let given = Json::parse(&acts_as_by_default(ir, "System").unwrap()).unwrap();
        let policy = &given.get("policies").unwrap().each()[0];
        assert_eq!(
            policy.get("acts_as").and_then(Json::as_str),
            Some("Operator")
        );
    }
}
