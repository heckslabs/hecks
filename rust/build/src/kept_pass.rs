//! Rust port of `ShapeLedger::Kept` (`lib/hecks/shape_ledger/kept.rb`): whether the target's data
//! is kept, which the host reads from `ir.json`'s `kept` key (ADR 0190). `hecks-build` has no
//! registry, so it answers from the same declarations the lineage pass reads: the hecksagon's binds,
//! the world's default adapter and the world's `disposable_ledger` setting.

use std::collections::HashMap;
use std::path::Path;

use crate::json::Json;
use crate::lineage_pass;
use crate::resolve;

/// Sets `ir["kept"]` to whether the target's data is kept: it is a framework member, or its first
/// aggregate binds a lineage-capable adapter that the committed world does not mark
/// `disposable_ledger`. A bluebook with no aggregate is bound to `Memory`.
///
/// # Errors
///
/// Returns a message naming a file or directory that cannot be read.
pub fn run(
    ir: &mut Json,
    hecksagon_path: Option<&Path>,
    world_path: Option<&Path>,
    world_default: Option<&str>,
    root: &Path,
) -> Result<(), String> {
    let name = ir.get("name").and_then(Json::as_str).unwrap_or_default();
    let framework = resolve::framework_members(root)?
        .iter()
        .any(|(n, _)| n == name);
    let first = ir
        .get("aggregates")
        .and_then(|a| a.each().first())
        .and_then(|a| a.get("name"))
        .and_then(Json::as_str)
        .map(str::to_string);
    let binds = match hecksagon_path {
        Some(path) => lineage_pass::persistence_binds(&read(path)?),
        None => HashMap::new(),
    };
    let world_text = match world_path {
        Some(path) => read(path)?,
        None => String::new(),
    };
    let capable = lineage_pass::lineage_capable_adapter_names(root)?;
    let adapter = adapter_of(first.as_deref(), &binds, world_default);
    let era = capable.iter().any(|c| c == adapter);
    ir.set_bool(
        "kept",
        framework || (era && !disposable(&world_text, adapter)),
    );
    Ok(())
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))
}

fn adapter_of<'a>(
    first: Option<&str>,
    binds: &'a HashMap<String, String>,
    world_default: Option<&'a str>,
) -> &'a str {
    first
        .and_then(|name| binds.get(name))
        .map(String::as_str)
        .or(world_default)
        .unwrap_or("Memory")
}

/// Whether the world's `persisted_by("<adapter>") do ... end` block sets `disposable_ledger true`.
/// `hecks-parse world` keeps setting names only, so the value is read from the block's text: a
/// setting is one line, and the block ends at the first line that is only `end`.
fn disposable(world_text: &str, adapter: &str) -> bool {
    let opener = format!("persisted_by(\"{adapter}\")");
    let mut inside = false;
    for line in world_text.lines().map(str::trim) {
        if line.starts_with(&opener) && line.ends_with("do") {
            inside = true;
        } else if inside && line == "end" {
            inside = false;
        } else if inside && sets_true(line) {
            return true;
        }
    }
    false
}

fn sets_true(line: &str) -> bool {
    let Some(value) = line.strip_prefix("disposable_ledger") else {
        return false;
    };
    matches!(value.trim(), "true" | "\"true\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISPOSABLE: &str = "persisted_by(\"PostgresEra\") do\n  disposable_ledger true\nend\n";

    #[test]
    fn a_block_marking_the_ledger_disposable_is_disposable() {
        assert!(disposable(DISPOSABLE, "PostgresEra"));
    }

    #[test]
    fn a_setting_in_another_adapters_block_does_not_count() {
        let text = "persisted_by(\"Heki\") do\n  disposable_ledger true\nend\n";
        assert!(!disposable(text, "PostgresEra"));
    }

    #[test]
    fn other_settings_or_false_are_not_disposable() {
        let text = "persisted_by(\"PostgresEra\") do\n  allow_superuser true\n  disposable_ledger false\nend\n";
        assert!(!disposable(text, "PostgresEra"));
    }

    #[test]
    fn a_setting_after_the_block_ends_does_not_count() {
        let text = "persisted_by(\"PostgresEra\") do\nend\ndisposable_ledger true\n";
        assert!(!disposable(text, "PostgresEra"));
    }

    #[test]
    fn the_adapter_is_the_bind_then_the_world_default_then_memory() {
        let binds = HashMap::from([("A".to_string(), "Heki".to_string())]);
        assert_eq!(adapter_of(Some("A"), &binds, Some("PostgresEra")), "Heki");
        assert_eq!(
            adapter_of(Some("B"), &binds, Some("PostgresEra")),
            "PostgresEra"
        );
        assert_eq!(adapter_of(None, &binds, None), "Memory");
    }
}
