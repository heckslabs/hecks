//! Rust port of `Exporter.lineage` (`lib/hecks/projector/exporter.rb`), by way
//! of the retired Ruby pipeline's `derive_lineage`.

use std::collections::HashMap;
use std::path::Path;

use crate::json::Json;

/// Sets `ir["lineage"]` to `{"capable_aggregates": [{"name":, "storage_name":}, ...]}`,
/// matching `Exporter.lineage`'s own output shape.
///
/// An aggregate with no `persisted_by` bind falls back to `world_path`'s own
/// `default_adapter` for the target chapter, then to `"Memory"`.
pub fn run(ir: &mut Json, hecksagon_path: Option<&Path>, world_path: Option<&Path>, root: &Path) -> Result<(), String> {
    let binds = match hecksagon_path {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
            persistence_binds(&text)
        }
        None => HashMap::new(),
    };
    let chapter_name = ir.get("name").and_then(Json::as_str).unwrap_or_default().to_string();
    let fallback_adapter = match world_path {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
            default_adapter_name(&text, &chapter_name)
        }
        None => None,
    }
    .unwrap_or_else(|| "Memory".to_string());
    let capable_adapters = lineage_capable_adapter_names(root)?;

    // Collected up front: Rust can't hold this borrow of `ir` alongside the
    // `&mut` call to `ir.set` below.
    let aggregate_names: Vec<String> = ir
        .get("aggregates")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter_map(|a| a.get("name").and_then(Json::as_str).map(str::to_string))
        .collect();

    let capable_aggregates: Vec<Json> = aggregate_names
        .into_iter()
        .filter(|name| {
            let adapter_name = binds.get(name.as_str()).map(String::as_str).unwrap_or(fallback_adapter.as_str());
            capable_adapters.iter().any(|a| a == adapter_name)
        })
        .map(|name| {
            let storage_name = snake_case(&name);
            Json::Object(vec![("name".to_string(), Json::String(name)), ("storage_name".to_string(), Json::String(storage_name))])
        })
        .collect();

    ir.set("lineage", Json::Object(vec![("capable_aggregates".to_string(), Json::Array(capable_aggregates))]));
    Ok(())
}

// Skips any line naming `role:` — only a role-less bind is authoritative.
pub(crate) fn persistence_binds(text: &str) -> HashMap<String, String> {
    let mut binds = HashMap::new();

    for line in text.lines() {
        if line.contains("role:") {
            continue;
        }

        let Some(call_pos) = line.find(".persisted_by(") else { continue };

        let before = &line[..call_pos];
        let aggregate_name: String = before.chars().rev().take_while(|c| c.is_alphanumeric() || *c == '_').collect::<String>().chars().rev().collect();
        if aggregate_name.is_empty() {
            continue;
        }

        let after = &line[call_pos + ".persisted_by(".len()..];
        let Some(open_quote) = after.find('"') else { continue };
        let rest = &after[open_quote + 1..];
        let Some(close_quote) = rest.find('"') else { continue };
        let adapter_name = &rest[..close_quote];

        binds.insert(aggregate_name, adapter_name.to_string());
    }

    binds
}

// Only lines inside the target chapter's own `Hecks.world` block count; the
// last `default_adapter` there wins, matching the Ruby builder.
pub(crate) fn default_adapter_name(text: &str, chapter: &str) -> Option<String> {
    let mut in_target_world = false;
    let mut found = None;

    for line in text.lines() {
        if let Some(opened) = world_opener_name(line) {
            in_target_world = opened == chapter;
            continue;
        }
        if !in_target_world {
            continue;
        }

        let Some(rest) = line.trim_start().strip_prefix("default_adapter") else { continue };
        if !rest.starts_with(char::is_whitespace) {
            continue;
        }
        let Some(open_quote) = rest.find('"') else { continue };
        let quoted = &rest[open_quote + 1..];
        let Some(close_quote) = quoted.find('"') else { continue };
        found = Some(quoted[..close_quote].to_string());
    }

    found
}

fn world_opener_name(line: &str) -> Option<String> {
    let rest = line.strip_prefix("Hecks.world")?;
    let quoted = &rest[rest.find('"')? + 1..];
    Some(quoted[..quoted.find('"')?].to_string())
}

// Where an adapter class can live: the driven adapters, and the era plugin that holds `PostgresEra`,
// the one adapter that declares itself lineage-capable.
const ADAPTER_DIRS: [&str; 2] = ["lib/hecks/adapters/driven", "lib/hecks/ports/persistence/plugins/era"];

// Reads each adapter's own source file rather than invoking Ruby.
fn lineage_capable_adapter_names(root: &Path) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    for relative in ADAPTER_DIRS {
        let dir = root.join(relative);
        let entries = std::fs::read_dir(&dir).map_err(|e| format!("reading {}: {e}", dir.display()))?;

        for entry in entries {
            let entry = entry.map_err(|e| format!("reading {}: {e}", dir.display()))?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("rb") {
                continue;
            }

            let text = std::fs::read_to_string(&path).map_err(|e| format!("reading {}: {e}", path.display()))?;
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
            let name: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
            if !name.is_empty() {
                return Some(name);
            }
        }
    }
    None
}

// Hand-ported `Naming.snake` (Ruby): split acronym boundaries, then camelCase
// boundaries, then downcase — no regex dependency.
pub(crate) fn snake_case(name: &str) -> String {
    let after_pass1 = split_acronym_boundaries(name);
    let after_pass2 = split_camel_boundaries(&after_pass1);
    after_pass2.to_ascii_lowercase()
}

fn split_acronym_boundaries(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len() + 4);
    let mut i = 0;
    while i < chars.len() {
        // A maximal uppercase run starting at i.
        if chars[i].is_ascii_uppercase() {
            let mut run_end = i;
            while run_end < chars.len() && chars[run_end].is_ascii_uppercase() {
                run_end += 1;
            }
            let run_len = run_end - i;
            let followed_by_lowercase = run_end < chars.len() && chars[run_end].is_ascii_lowercase();
            if run_len >= 2 && followed_by_lowercase {
                // Emit the run minus its last char, an underscore, then
                // continue scanning from the run's own last char (which
                // pass 2 or a plain copy picks up next iteration).
                out.extend(&chars[i..run_end - 1]);
                out.push('_');
                i = run_end - 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn split_camel_boundaries(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len() + 4);
    for (idx, &c) in chars.iter().enumerate() {
        if idx > 0 {
            let prev = chars[idx - 1];
            if (prev.is_ascii_lowercase() || prev.is_ascii_digit()) && c.is_ascii_uppercase() {
                out.push('_');
            }
        }
        out.push(c);
    }
    out
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
            assert_eq!(snake_case(input), expected, "snake_case({input:?})");
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
    fn reads_the_default_adapter_of_the_target_chapters_own_world_only() {
        let text = "Hecks.world \"Alpha\" do\n  # default_adapter \"Heki\"\n  default_adapter \"PostgresEra\"\nend\n\nHecks.world(\"Beta\") do\n  default_adapter \"Memory\"\nend\n";
        assert_eq!(default_adapter_name(text, "Alpha"), Some("PostgresEra".to_string()));
        assert_eq!(default_adapter_name(text, "Beta"), Some("Memory".to_string()));
        assert_eq!(default_adapter_name(text, "Gamma"), None);
    }

    #[test]
    fn declares_lineage_capable_true_matches_the_endless_method_form() {
        assert!(declares_lineage_capable_true("      def self.lineage_capable? = true\n"));
        assert!(!declares_lineage_capable_true("      def self.lineage_capable? = false\n"));
        assert!(!declares_lineage_capable_true("no such method here\n"));
    }

    // The adapter moved out of `lib/hecks/adapters/driven` once and the scan silently found none, which
    // left every lineage-capable aggregate out of a Ruby-free build's `ir.json`.
    #[test]
    fn finds_postgres_era_in_the_real_source_tree() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let names = lineage_capable_adapter_names(&root).expect("scans the adapter directories");
        assert!(names.iter().any(|name| name == "PostgresEra"), "lineage-capable adapters found: {names:?}");
    }

    #[test]
    fn finds_the_top_level_class_name() {
        assert_eq!(top_level_class_name("module Hecks\n  module Adapters\n    class Postgres\n      def x; end\n"), Some("Postgres".to_string()));
    }
}
