//! Rust port of the binding facts `lib/hecks/rust_build/project_rust/target_ir.rb` adds beside the
//! declared IR: `persistence`, `adapters` (the bound adapters' declarations, from the closure
//! the caller passes), `translations` and `source_text`. The capability seams
//! (authorization, identity, payments, ...) are `seams_pass`'s.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::lineage_pass;
use crate::translation_pass;

/// Sets `persistence`, the first of the binding facts, in `TargetIr#call`'s order.
pub fn run(
    ir: &mut Json,
    hecksagon_path: Option<&Path>,
    world_default: Option<&str>,
    adapter_declarations: impl FnOnce(&Json) -> Result<Json, String>,
) -> Result<(), String> {
    let declaration_name = ir
        .get("name")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_string();
    let persistence = persistence(ir, &declaration_name, hecksagon_path, world_default)?;
    ir.set("persistence", persistence);
    let adapters = adapter_declarations(ir)?;
    ir.set("adapters", adapters);
    Ok(())
}

/// Sets `translations` and `source_text`, after the capability seams so the key order matches
/// `TargetIr#call`.
///
/// `translations` carries each `translations/*.bluebook` edge with its precompiled SQL, from
/// `translation_pass`; an edge using a rule kind that pass does not compile is refused, never
/// shipped without its SQL. A `translates` declaration in a bluebook is refused outright.
pub fn finish(
    ir: &mut Json,
    bluebook_files: &[PathBuf],
    bluebook_dir: &Path,
) -> Result<(), String> {
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
    ir.set(
        "translations",
        Json::Array(translation_pass::edges(bluebook_dir)?),
    );
    if !texts.is_empty() {
        ir.set("source_text", Json::String(texts.join("\n")));
    }
    Ok(())
}

fn declares_translation(line: &str) -> bool {
    let line = line.trim_start();
    line.starts_with("translates") || line.starts_with("translation ")
}

fn persistence(
    ir: &Json,
    declaration: &str,
    hecksagon: Option<&Path>,
    world_default: Option<&str>,
) -> Result<Json, String> {
    let (binds, hecksagon_default) = match hecksagon {
        Some(path) => {
            let text = read(path)?;
            (
                lineage_pass::persistence_binds(&text),
                domain_default(&text, declaration)?,
            )
        }
        None => (HashMap::new(), None),
    };
    let declared = hecksagon_default.or_else(|| world_default.map(str::to_string));
    let mut aggregates = Vec::new();
    for aggregate in ir.get("aggregates").map_or(&[][..], Json::each) {
        let name = aggregate
            .get("name")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_string();
        let adapter = match (binds.get(&name), &declared, hecksagon.is_some()) {
            (Some(adapter), _, _) => adapter.clone(),
            (None, Some(adapter), _) => adapter.clone(),
            (None, None, false) => "Memory".to_string(),
            (None, None, true) => {
                return Err(format!("{declaration}::{name} has no persisted_by bind, and its hecksagon names no default adapter"));
            }
        };
        aggregates.push(Json::Object(vec![
            ("name".to_string(), Json::String(name.clone())),
            (
                "storage_name".to_string(),
                Json::String(crate::hecks_naming::snake(&name)),
            ),
            ("adapter".to_string(), Json::String(adapter)),
        ]));
    }
    Ok(Json::Object(vec![(
        "aggregates".to_string(),
        Json::Array(aggregates),
    )]))
}

// The bare `persisted_by "X"` line of the bluebook's own `Hecks.hecksagon` block: every aggregate
// without a bind of its own inherits it. The last one in the block wins.
//
// The line is read as text, not evaluated, so anything after the adapter's name (a guard such as
// `if ENV[...]`, or an option) cannot be honored here. Such a line is refused rather than read as
// an unconditional bind, because the build and the Ruby loader would then disagree on the adapter.
fn domain_default(text: &str, declaration: &str) -> Result<Option<String>, String> {
    let mut in_bluebook = false;
    let mut found = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("Hecks.hecksagon") {
            in_bluebook = rest.contains(&format!("\"{declaration}\""));
            continue;
        }
        let Some(rest) = line.trim_start().strip_prefix("persisted_by ") else {
            continue;
        };
        let Some(open) = rest.find('"').filter(|_| in_bluebook) else {
            continue;
        };
        let quoted = &rest[open + 1..];
        let Some(close) = quoted.find('"') else {
            found = None;
            continue;
        };
        let after = quoted[close + 1..].trim();
        if !after.is_empty() && !after.starts_with('#') {
            return Err(format!(
                "{declaration}'s hecksagon has `persisted_by` with `{after}` after the adapter; \
                 the build cannot evaluate that, so the bind is refused. Remove the condition, \
                 or wire the adapter in a hecksagon that applies to it."
            ));
        }
        found = Some(quoted[..close].to_string());
    }
    Ok(found)
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::domain_default;

    #[test]
    fn a_bare_bind_names_the_domain_default() {
        let text = "Hecks.hecksagon \"Miette\" do\n  persisted_by \"PostgresEra\"\nend\n";
        assert_eq!(
            domain_default(text, "Miette"),
            Ok(Some("PostgresEra".to_string()))
        );
    }

    #[test]
    fn a_trailing_comment_is_not_a_condition() {
        let text = "Hecks.hecksagon \"Miette\" do\n  persisted_by \"Memory\" # in-memory by default\nend\n";
        assert_eq!(
            domain_default(text, "Miette"),
            Ok(Some("Memory".to_string()))
        );
    }

    #[test]
    fn a_guarded_bind_is_refused_not_read_as_unconditional() {
        let text = "Hecks.hecksagon \"Miette\" do\n  persisted_by \"PostgresEra\" if ENV[\"MIETTE_LOCAL\"]\nend\n";
        let err = domain_default(text, "Miette").unwrap_err();
        assert!(err.contains("`if ENV[\"MIETTE_LOCAL\"]`"), "{err}");
    }

    #[test]
    fn a_bind_in_another_bluebook_is_ignored() {
        let text =
            "Hecks.hecksagon \"Other\" do\n  persisted_by \"PostgresEra\" if ENV[\"X\"]\nend\n";
        assert_eq!(domain_default(text, "Miette"), Ok(None));
    }
}
