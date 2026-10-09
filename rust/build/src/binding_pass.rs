//! Rust port of the binding facts `lib/hecks/rust_build/project_rust/target_ir.rb` adds beside the
//! declared IR: `persistence`, `translations` and `source_text`. The capability seams
//! (authorization, identity, payments, ...) are `seams_pass`'s.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::lineage_pass;

/// Sets `persistence`, the first of the binding facts, in `TargetIr#call`'s order.
pub fn run(ir: &mut Json, hecksagon_path: Option<&Path>, world_path: Option<&Path>) -> Result<(), String> {
    let chapter_name = ir.get("name").and_then(Json::as_str).unwrap_or_default().to_string();
    let persistence = persistence(ir, &chapter_name, hecksagon_path, world_path)?;
    ir.set("persistence", persistence);
    Ok(())
}

/// Sets `translations` and `source_text`, after the capability seams so the key order matches
/// `TargetIr#call`.
///
/// `translations` is always empty: a domain whose source declares a translation is refused, since
/// its edges carry precompiled SQL that only the Ruby `Translation::RuleCompiler` produces.
pub fn finish(ir: &mut Json, bluebook_files: &[PathBuf], bluebook_dir: &Path) -> Result<(), String> {
    refuse_translation_files(bluebook_dir)?;
    let mut texts = Vec::new();
    for path in bluebook_files {
        let text = read(path)?;
        if text.lines().any(declares_translation) {
            return Err(format!(
                "{} declares a translation; hecks-build cannot compile its SQL yet, so generate this domain with the Ruby toolchain",
                path.display()
            ));
        }
        texts.push(text);
    }
    ir.set("translations", Json::Array(Vec::new()));
    if !texts.is_empty() {
        ir.set("source_text", Json::String(texts.join("\n")));
    }
    Ok(())
}

// A translation is a `.bluebook` under the domain's `translations/` directory, one per era step.
fn refuse_translation_files(bluebook_dir: &Path) -> Result<(), String> {
    let Ok(entries) = std::fs::read_dir(bluebook_dir.join("translations")) else { return Ok(()) };
    let declared = entries.filter_map(Result::ok).any(|entry| entry.path().extension().and_then(|e| e.to_str()) == Some("bluebook"));
    if declared {
        return Err(format!(
            "{} declares translations; hecks-build cannot compile their SQL yet, so generate this domain with the Ruby toolchain",
            bluebook_dir.display()
        ));
    }
    Ok(())
}

fn declares_translation(line: &str) -> bool {
    let line = line.trim_start();
    line.starts_with("translates") || line.starts_with("translation ")
}

fn persistence(ir: &Json, chapter: &str, hecksagon: Option<&Path>, world: Option<&Path>) -> Result<Json, String> {
    let (binds, hecksagon_default) = match hecksagon {
        Some(path) => {
            let text = read(path)?;
            (lineage_pass::persistence_binds(&text), domain_default(&text, chapter))
        }
        None => (HashMap::new(), None),
    };
    let world_default = match world {
        Some(path) => lineage_pass::default_adapter_name(&read(path)?, chapter),
        None => None,
    };
    let declared = hecksagon_default.or(world_default);
    let mut aggregates = Vec::new();
    for aggregate in ir.get("aggregates").map(Json::each).unwrap_or(&[]) {
        let name = aggregate.get("name").and_then(Json::as_str).unwrap_or_default().to_string();
        let adapter = match (binds.get(&name), &declared, hecksagon.is_some()) {
            (Some(adapter), _, _) => adapter.clone(),
            (None, Some(adapter), _) => adapter.clone(),
            (None, None, false) => "Memory".to_string(),
            (None, None, true) => {
                return Err(format!("{chapter}::{name} has no persisted_by bind, and its hecksagon names no default adapter"));
            }
        };
        aggregates.push(Json::Object(vec![
            ("name".to_string(), Json::String(name.clone())),
            ("storage_name".to_string(), Json::String(lineage_pass::snake_case(&name))),
            ("adapter".to_string(), Json::String(adapter)),
        ]));
    }
    Ok(Json::Object(vec![("aggregates".to_string(), Json::Array(aggregates))]))
}

// The bare `persisted_by "X"` line of the chapter's own `Hecks.hecksagon` block: every aggregate
// without a bind of its own inherits it. The last one in the block wins.
fn domain_default(text: &str, chapter: &str) -> Option<String> {
    let mut in_chapter = false;
    let mut found = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("Hecks.hecksagon") {
            in_chapter = rest.contains(&format!("\"{chapter}\""));
            continue;
        }
        let Some(rest) = line.trim_start().strip_prefix("persisted_by ") else { continue };
        let Some(open) = rest.find('"').filter(|_| in_chapter) else { continue };
        let quoted = &rest[open + 1..];
        found = quoted.find('"').map(|close| quoted[..close].to_string());
    }
    found
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))
}
