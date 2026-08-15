//! A Rust port of `Exporter.lineage` (`lib/hecksagain/projector/exporter.rb`)
//! by way of `rust/project_rust_pipeline.rb::derive_lineage` — the SECOND
//! (and, as of this module, LAST) named gap `pipeline.rs`'s own header used
//! to carry. Read `rust/project_rust_pipeline.rb`'s own header on
//! `derive_lineage` in full before touching this file — it explains, at
//! length, exactly why a narrow text scan for ONE specific bind shape
//! (`<Ns>::<Aggregate>.persisted_by("Adapter")`, no `role:`) closes this
//! gap without reopening ADR 0023's own permanent open-vocabulary escape
//! for `.hecksagon` adapter binds (`parse::hecksagon` still shape-matches
//! and drops everything, unchanged) — this module mirrors that Ruby
//! function line for line, at the same orchestration tier
//! `optional_pass` already occupies, never inside `rust/parser`/
//! `rust/codegen` themselves.
//!
//! THE ONE FACT NEEDED PER AGGREGATE: which adapter its sole authoritative
//! `persisted_by` bind names (`Ports::Persistence::BindingPolicy.resolve`),
//! checked against which adapters declare `lineage_capable? = true`
//! (`EraCheck.lineage_capable?`) — read off both sources the same "plain
//! text scanning of a file, not DSL execution" way `resolve::header_
//! chapter_name` already reads a bluebook's own header line.

use std::collections::HashMap;
use std::path::Path;

use crate::json::Json;

/// `derive_lineage` (Ruby) — sets `ir["lineage"]` to
/// `{"capable_aggregates": [{"name":, "storage_name":}, ...]}`, matching
/// `Exporter.lineage`'s own output shape exactly. `hecksagon_path: None`
/// (no `.hecksagon` file at all) means every aggregate is unbound —
/// `BindingPolicy.default_binding`'s own "Memory" answer, never
/// lineage-capable — so `capable_aggregates` comes back empty without
/// this function needing to special-case it.
pub fn run(ir: &mut Json, hecksagon_path: Option<&Path>, root: &Path) -> Result<(), String> {
    let binds = match hecksagon_path {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
            persistence_binds(&text)
        }
        None => HashMap::new(),
    };
    let capable_adapters = lineage_capable_adapter_names(root)?;

    // Collected up front, not read live off `ir` while building the
    // replacement — same "gather, then apply" split `optional_pass`'s
    // own header explains, for the same reason: Rust can't hold this
    // immutable borrow of `ir` at the same time as the `&mut` `ir.set`
    // call below.
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
            let adapter_name = binds.get(name.as_str()).map(String::as_str).unwrap_or("Memory");
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

/// PLAIN TEXT SCANNING for one specific shape — see this module's own
/// header. Skips any line naming a `role:` (the sole exclusion
/// `BindingPolicy.resolve`'s own "authoritative" filter applies; every
/// real corpus `persisted_by` call today is role-less, so this is a
/// completeness guard against a FUTURE role-bearing bind, not dead code
/// against the present corpus). The aggregate's own BARE name is
/// whatever identifier run sits immediately before `.persisted_by(` —
/// `Naming.demodulise`'s own job (strip everything up to the last `::`)
/// falls out of taking the LAST identifier-character run in that
/// position, with no separate demodulise step needed.
fn persistence_binds(text: &str) -> HashMap<String, String> {
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

/// Which adapters carry eras — read off their own source, the same
/// "structural fact about a file" precedent this module's own header
/// establishes, so a second lineage-capable adapter arriving needs no
/// change here (mirrors `EraCheck.lineage_capable?`'s own "the
/// capability is asked of the adapter, never of its name" design).
fn lineage_capable_adapter_names(root: &Path) -> Result<Vec<String>, String> {
    let dir = root.join("lib/hecksagain/adapters/driven");
    let entries = std::fs::read_dir(&dir).map_err(|e| format!("reading {}: {e}", dir.display()))?;

    let mut names = Vec::new();
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

    Ok(names)
}

/// `text =~ /lineage_capable\?\s*=\s*true/` (Ruby), by hand: every
/// occurrence of the literal method name, followed (past only
/// whitespace) by `= true` — matches `def self.lineage_capable? = true`
/// (the endless-method form every real adapter in this corpus uses)
/// without needing a regex dependency for one fixed pattern.
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

/// The first `class Name` line's own name — every adapter file in this
/// corpus declares exactly one primary class this way (`class PostgresEra`
/// under `module Hecksagain; module Adapters; ...; end; end`), so the
/// first match is the adapter's own registration name, the same short
/// spelling `persisted_by("PostgresEra")` itself uses.
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

/// `Naming.snake` (Ruby), ported by hand rather than with a regex
/// dependency — two passes over the same fixed two-step substitution
/// `naming.rb`'s own body performs, then a final ASCII downcase (every
/// real aggregate name in this corpus is plain ASCII PascalCase, the
/// same assumption `Naming.snake`'s own callers already make):
///
/// PASS 1 (`gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')`) — an ACRONYM-TO-WORD
/// boundary: a maximal run of 2+ uppercase letters immediately followed
/// by a lowercase letter gets an underscore inserted before the run's
/// OWN LAST letter (`"ATMCard"` → `"ATM_Card"`: the run is `"ATMC"`,
/// followed by `'a'`, so the underscore lands before `'C'` — verified
/// against `Hecksagain::Naming.snake("ATMCard")` directly, a real
/// corpus name (`Banking::ATMCard`) this exact shape needs). A run of
/// exactly 1 uppercase letter never matches this pass at all (the regex
/// needs 2 separate uppercase-letter matches minimum — one for each
/// capture group), so an ordinary word-initial capital
/// (`"SafeDepositBox"`'s own `S`/`D`/`B`) is untouched here.
///
/// PASS 2 (`gsub(/([a-z\d])([A-Z])/, '\1_\2')`) — the ordinary
/// camelCase boundary: a lowercase letter or digit immediately followed
/// by an uppercase letter gets an underscore inserted between them
/// (`"SafeDepositBox"` → `"Safe_Deposit_Box"`).
fn snake_case(name: &str) -> String {
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

    #[test]
    fn snake_cases_a_plain_pascal_name() {
        assert_eq!(snake_case("Order"), "order");
    }

    #[test]
    fn snake_cases_a_multi_word_name_with_no_acronym() {
        assert_eq!(snake_case("SafeDepositBox"), "safe_deposit_box");
    }

    #[test]
    fn snake_cases_a_leading_acronym_followed_by_a_word() {
        assert_eq!(snake_case("ATMCard"), "atm_card");
    }

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
    fn declares_lineage_capable_true_matches_the_endless_method_form() {
        assert!(declares_lineage_capable_true("      def self.lineage_capable? = true\n"));
        assert!(!declares_lineage_capable_true("      def self.lineage_capable? = false\n"));
        assert!(!declares_lineage_capable_true("no such method here\n"));
    }

    #[test]
    fn finds_the_top_level_class_name() {
        assert_eq!(top_level_class_name("module Hecksagain\n  module Adapters\n    class Postgres\n      def x; end\n"), Some("Postgres".to_string()));
    }
}
