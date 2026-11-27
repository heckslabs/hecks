//! Rust port of `Exporter.lineage` (`lib/hecks/projector/exporter.rb`), by way
//! of the retired Ruby pipeline's `derive_lineage`.

use std::collections::HashMap;
use std::path::Path;

use crate::json::Json;

/// Sets `ir["lineage"]` to `{"capable_aggregates": [{"name":, "storage_name":}, ...]}`,
/// matching `Exporter.lineage`'s own output shape.
///
/// An aggregate with no `persisted_by` bind falls back to the world's `default_adapter` for the
/// target bluebook, then to `"Memory"`. An aggregate is capable when it binds Postgres and the
/// hecksagon sets `revisions true`: the revision layout (ADR 0182).
pub fn run(
    ir: &mut Json,
    hecksagon_path: Option<&Path>,
    world_default: Option<&str>,
    _root: &Path,
) -> Result<(), String> {
    let text = match hecksagon_path {
        Some(path) => {
            std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?
        }
        None => String::new(),
    };
    let binds = persistence_binds(&text);
    let fallback_adapter = world_default.unwrap_or("Memory").to_string();

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
            revision_layout(adapter_name, &text)
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

/// The one adapter whose hecksagon can choose the revision layout, as Ruby's `Postgres.layout_class`.
pub(crate) const REVISION_ADAPTER: &str = "Postgres";

/// Whether an aggregate bound to `adapter` in the hecksagon `text` keeps Postgres's revision
/// layout, the one layout with eras and lineage: Ruby's `Ports::Persistence::Layout`.
pub(crate) fn revision_layout(adapter: &str, text: &str) -> bool {
    adapter == REVISION_ADAPTER && declares_revisions(text)
}

// The hecksagon's last `revisions` line decides, as the DSL's `revisions(on = true)` does: bare
// `revisions` and `revisions true` turn it on, `revisions false` off.
fn declares_revisions(text: &str) -> bool {
    text.lines()
        .map(|line| line.split('#').next().unwrap_or_default().trim())
        .filter_map(|line| line.strip_prefix("revisions"))
        .filter(|rest| rest.is_empty() || rest.starts_with([' ', '(']))
        .map(|rest| rest.trim_matches(|c: char| c.is_whitespace() || c == '(' || c == ')'))
        .next_back()
        .is_some_and(|value| value.is_empty() || value == "true")
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
    fn postgres_with_revisions_true_is_the_revision_layout() {
        let text = "Hecks.hecksagon \"Shop\" do\n  Shop::Order.persisted_by(\"Postgres\")\n  revisions true\nend\n";
        assert!(revision_layout("Postgres", text));
    }

    #[test]
    fn postgres_without_revisions_is_the_table_layout() {
        let text = "Hecks.hecksagon \"Shop\" do\n  Shop::Order.persisted_by(\"Postgres\")\nend\n";
        assert!(!revision_layout("Postgres", text));
    }

    #[test]
    fn the_last_revisions_line_decides() {
        assert!(!declares_revisions("  revisions true\n  revisions false\n"));
        assert!(declares_revisions("  revisions\n"));
        assert!(!declares_revisions(
            "  revisions_kept true\n  # revisions true\n"
        ));
    }

    #[test]
    fn revisions_on_another_adapter_is_no_revision_layout() {
        assert!(!revision_layout("Memory", "  revisions true\n"));
    }

    // Ruby picks the layout in `Postgres.layout_class`; if that moves, this pass no longer
    // describes what Ruby boots.
    #[test]
    fn ruby_postgres_picks_its_layout_from_revisions() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../lib/hecks/adapters/driven/postgres.rb");
        let text = std::fs::read_to_string(&path).expect("reads postgres.rb");
        assert!(
            text.contains("def self.layout_class(revisions:)"),
            "{}",
            path.display()
        );
    }
}
