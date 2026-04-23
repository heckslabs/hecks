//! Rust port of `lib/hecks_specializer/validator.rb`.
//!
//! Emits `hecks_life/src/validator.rs` byte-identical to the Ruby
//! specializer's output. Reads `ValidatorEntryPoint`, `ValidationRule`,
//! `SuffixTable`, and `ExceptionWord` rows from validator_shape and
//! assembles: header → imports → entry point → rule → rule →
//! command_naming_support → remaining rules. All emission is inline —
//! no `.rs.frag` snippets (per the Phase D plan, validator is the
//! "all-inline Ruby" specializer).
//!
//! Per-concern split (to stay under the 200-LoC cap):
//!   this file                       — orchestration, header / imports /
//!                                      entry-point
//!   validator_checks.rs             — four local check_kind emitters
//!                                      (unique, non_empty,
//!                                      first_word_verb, unique_across)
//!   validator_checks_graph.rs       — three graph-walking check_kind
//!                                      emitters (reference_valid,
//!                                      trigger_valid, distinct_aliases)
//!   validator_morphology.rs         — command_naming_support + the
//!                                      suffix / verb-exception /
//!                                      verb-suffix formatters
//!                                      (hand-aligned columns)
//!
//! Usage:
//!   let rust = validator::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/validator.rs —
//!  Phase D — Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use crate::specializer::validator_checks;
use crate::specializer::validator_morphology;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/validator_shape/fixtures/validator_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let mut out = String::new();
    out.push_str(HEADER);
    out.push_str(IMPORTS);
    out.push_str(&emit_entry_point(&fixtures)?);
    out.push_str(&validator_checks::emit_rule(
        &fixtures,
        find_rule(&fixtures, "unique_aggregate_names")?,
    ));
    out.push_str(&validator_checks::emit_rule(
        &fixtures,
        find_rule(&fixtures, "aggregates_have_commands")?,
    ));
    out.push_str(&validator_morphology::emit_command_naming_support(&fixtures));
    for rust_fn_name in [
        "command_naming",
        "valid_references",
        "valid_policy_triggers",
        "no_duplicate_commands",
        "distinct_reference_aliases",
    ] {
        out.push_str(&validator_checks::emit_rule(
            &fixtures,
            find_rule(&fixtures, rust_fn_name)?,
        ));
    }
    Ok(out)
}

fn find_rule<'a>(
    fixtures: &'a [Fixture],
    rust_fn_name: &str,
) -> Result<&'a Fixture, Box<dyn Error>> {
    util::by_aggregate(fixtures, "ValidationRule")
        .into_iter()
        .find(|r| util::attr(r, "rust_fn_name") == rust_fn_name)
        .ok_or_else(|| {
            format!("no ValidationRule fixture with rust_fn_name={}", rust_fn_name).into()
        })
}

fn emit_entry_point(fixtures: &[Fixture]) -> Result<String, Box<dyn Error>> {
    let entry = util::by_aggregate(fixtures, "ValidatorEntryPoint")
        .into_iter()
        .next()
        .ok_or("no ValidatorEntryPoint fixture")?;
    let fn_name = util::attr(entry, "fn_name");
    let returns = util::attr(entry, "returns");
    let collects_into = util::attr(entry, "collects_into");
    let rules: Vec<String> = util::attr(entry, "rule_order")
        .split(',')
        .map(|r| format!("    errors.extend({}(domain));", r.trim()))
        .collect();

    Ok(format!(
        "\
/// Run all validation rules and return collected errors.
pub fn {fn_name}(domain: &Domain) -> {returns} {{
    let mut {collects_into} = vec![];
{rules_block}
    {collects_into}
}}

",
        fn_name = fn_name,
        returns = returns,
        collects_into = collects_into,
        rules_block = rules.join("\n"),
    ))
}

const HEADER: &str = "\
//! Domain validator — checks a parsed domain for DDD consistency
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_shape/
//! Regenerate: bin/specialize validator --output hecks_life/src/validator.rs
//! Contract:  specializer.hecksagon :specialize_validator shell adapter
//! Tests:     hecks_life/tests/validator_rules_test.rs (moved out for i51 Phase A commit 4)
//!
//! Ports the Ruby Hecks::Validator rules to Rust. Each rule inspects
//! the Domain IR and returns error strings. An empty vec means valid.
//!
//! Usage:
//!   let errors = validator::validate(&domain);
//!   if errors.is_empty() { println!(\"VALID\"); }

";

const IMPORTS: &str = "\
use crate::ir::Domain;
use std::collections::HashSet;

";
