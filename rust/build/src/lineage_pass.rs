//! Rust port of `Exporter.lineage` (`lib/hecks/projector/exporter.rb`), by way
//! of the retired Ruby pipeline's `derive_lineage`.

use std::collections::HashMap;
use std::path::Path;

use crate::json::Json;

/// Sets `ir["lineage"]` to `{"capable_aggregates": [{"name":, "storage_name":}, ...]}`,
/// matching `Exporter.lineage`'s own output shape.
///
/// An aggregate with no `persisted_by` bind falls back to the world's `default_adapter` for the
/// target bluebook, then to `"Memory"`.
pub fn run(
    ir: &mut Json,
    hecksagon_path: Option<&Path>,
    world_default: Option<&str>,
    root: &Path,
) -> Result<(), String> {
    let binds = match hecksagon_path {
        Some(path) => {
            let text = std::fs::read_to_string(path)
                .map_err(|e| format!("reading {}: {e}", path.display()))?;
            persistence_binds(&text)
        }
        None => HashMap::new(),
    };
    let fallback_adapter = world_default.unwrap_or("Memory").to_string();
    let capable_adapters = lineage_capable_adapter_names(root)?;

    // Collected before `ir.set` below: Rust can't hold this borrow of `ir`
    // alongside the `&mut` call.
    let capable_aggregates: Vec<Json> = ir
        .get("aggregates")
        .map_or(&[][..], Json::each)
        .iter()
        .filter_map(|a| a.get("name").and_then(Json::as_str).map(str::to_string))
        .filter(|name| {
            let adapter_name = binds
                .get(name.as_str())
                .map_or(fallback_adapter.as_str(), String::as_str);
            capable_adapters.iter().any(|a| a == adapter_name)
        })
        .map(|name| {
            let storage_name = crate::hecks_naming::snake(&name);
            Json::Object(vec![
                ("name".to_string(), Json::String(name)),
                ("storage_name".to_string(), Json::String(storage_name)),
            ])
        })
        .collect();

    ir.set(
        "lineage",
        Json::Object(vec![(
            "capable_aggregates".to_string(),
            Json::Array(capable_aggregates),
        )]),
    );
    Ok(())
}

// Skips any line naming `role:` — only a role-less bind is authoritative.
pub(crate) fn persistence_binds(text: &str) -> HashMap<String, String> {
    let mut binds = HashMap::new();

    for line in text.lines() {
        if line.contains("role:") {
            continue;
        }

        let Some(call_pos) = line.find(".persisted_by(") else {
            continue;
        };

        let before = &line[..call_pos];
        let aggregate_name: String = before
            .chars()
            .rev()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        if aggregate_name.is_empty() {
            continue;
        }

        let after = &line[call_pos + ".persisted_by(".len()..];
        let Some(open_quote) = after.find('"') else {
            continue;
        };
        let rest = &after[open_quote + 1..];
        let Some(close_quote) = rest.find('"') else {
            continue;
        };
        let adapter_name = &rest[..close_quote];

        binds.insert(aggregate_name, adapter_name.to_string());
    }

    binds
}

// Where an adapter class can live: the driven adapters, and the era plugin that holds `PostgresEra`,
// the one adapter that declares itself lineage-capable.
const ADAPTER_DIRS: [&str; 2] = [
    "lib/hecks/adapters/driven",
    "lib/hecks/ports/persistence/plugins/era",
];

// Reads each adapter's own source file rather than invoking Ruby.
fn lineage_capable_adapter_names(root: &Path) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    for relative in ADAPTER_DIRS {
        let dir = root.join(relative);
        let entries =
            std::fs::read_dir(&dir).map_err(|e| format!("reading {}: {e}", dir.display()))?;

        for entry in entries {
            let entry = entry.map_err(|e| format!("reading {}: {e}", dir.display()))?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("rb") {
                continue;
            }

            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("reading {}: {e}", path.display()))?;
            if !declares_lineage_capable_true(&text) {
                continue;
            }
            if let Some(name) = top_level_class_name(&text) {
                names.push(name);
            }
        }
    }

    Ok(names)
}

// Matches `def self.lineage_capable? = true`, including the endless-method
// form, without a regex dependency.
fn declares_lineage_capable_true(text: &str) -> bool {
    const NEEDLE: &str = "lineage_capable?";
    let mut search_from = 0;
    while let Some(rel) = text[search_from..].find(NEEDLE) {
        let after = &text[search_from + rel + NEEDLE.len()..];
        let trimmed = after.trim_start();
        if trimmed.starts_with("= true") {
            return true;
        }
        search_from += rel + NEEDLE.len();
    }
    false
}

// Assumes one primary class per adapter file, matching the corpus.
fn top_level_class_name(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("class ") {
            let name: String = rest
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if !name.is_empty() {
                return Some(name);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Covers the plain-Pascal ("Order"), multi-word ("SafeDepositBox") and
    // leading-acronym ("ATMCard") shapes in one table.
    #[test]
    fn snake_cases_every_real_corpus_aggregate_name() {
        let cases = [
            ("Order", "order"),
            ("Customer", "customer"),
            ("LedgerEntry", "ledger_entry"),
            ("SafeDepositBox", "safe_deposit_box"),
            ("OnboardingCase", "onboarding_case"),
            ("ATMCard", "atm_card"),
            ("ExternalTransfer", "external_transfer"),
            ("ScheduledPayment", "scheduled_payment"),
            ("CardPayment", "card_payment"),
            ("RoleAssignment", "role_assignment"),
            ("RoleTransition", "role_transition"),
            ("Identity", "identity"),
            ("ExternalIdentifier", "external_identifier"),
            ("Statement", "statement"),
        ];
        for (input, expected) in cases {
            assert_eq!(
                crate::hecks_naming::snake(input),
                expected,
                "snake({input:?})"
            );
        }
    }

    #[test]
    fn extracts_a_role_less_bind_and_skips_a_role_bearing_one() {
        let text = "Hecks.hecksagon \"Banking\" do\n  Banking::Customer.persisted_by(\"Heki\")\n  Banking::Statement.persisted_by(\"Postgres\", role: :audit)\nend\n";
        let binds = persistence_binds(text);
        assert_eq!(binds.get("Customer").map(String::as_str), Some("Heki"));
        assert_eq!(binds.get("Statement"), None);
    }

    #[test]
    fn declares_lineage_capable_true_matches_the_endless_method_form() {
        assert!(declares_lineage_capable_true(
            "      def self.lineage_capable? = true\n"
        ));
        assert!(!declares_lineage_capable_true(
            "      def self.lineage_capable? = false\n"
        ));
        assert!(!declares_lineage_capable_true("no such method here\n"));
    }

    // The adapter moved out of `lib/hecks/adapters/driven` once and the scan silently found none, which
    // left every lineage-capable aggregate out of a Ruby-free build's `ir.json`.
    #[test]
    fn finds_postgres_era_in_the_real_source_tree() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let names = lineage_capable_adapter_names(&root).expect("scans the adapter directories");
        assert!(
            names.iter().any(|name| name == "PostgresEra"),
            "lineage-capable adapters found: {names:?}"
        );
    }

    #[test]
    fn finds_the_top_level_class_name() {
        assert_eq!(
            top_level_class_name(
                "module Hecks\n  module Adapters\n    class Postgres\n      def x; end\n"
            ),
            Some("Postgres".to_string())
        );
    }
}
