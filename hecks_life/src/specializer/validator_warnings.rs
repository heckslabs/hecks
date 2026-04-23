//! Rust port of `lib/hecks_specializer/validator_warnings.rb`.
//!
//! Emits `hecks_life/src/validator_warnings.rs` byte-identical to the
//! Ruby specializer's output. Reads the `WarningRule` fixture rows
//! from the validator_warnings shape, dispatches each row by
//! `body_strategy` (templated | embedded) and `check_kind`
//! (count_threshold for templated; embedded reads a `.rs.frag`
//! snippet whose leading `//`-comment header is stripped).
//!
//! Usage:
//!   let rust = validator_warnings::emit(repo_root)?;
//!   print!("{}", rust);

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/validator_warnings_shape/fixtures/validator_warnings_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let rules = util::by_aggregate(&fixtures, "WarningRule");

    let mut out = String::new();
    out.push_str(&emit_header());
    out.push_str(&emit_imports());
    for rule in rules {
        out.push_str(&emit_rule(repo_root, rule)?);
    }
    Ok(out)
}

fn emit_header() -> String {
    r#"//! Soft warnings for domain quality — non-failing bounded-context checks
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_warnings_shape/
//! Regenerate: bin/specialize validator_warnings --output hecks_life/src/validator_warnings.rs
//! Contract:  specializer.hecksagon :specialize_validator_warnings shell adapter
//! Tests:     hecks_life/tests/validator_warnings_test.rs
//!
//! These rules emit advisory warnings but never cause validation to fail.
//! They help domain modelers spot bounded-context smell early.
//!
//! Usage:
//!   if let Some(msg) = validator_warnings::aggregate_count_warning(&domain) {
//!       println!("  {}", msg);
//!   }
//!   if let Some(msg) = validator_warnings::mixed_concerns_warning(&domain) {
//!       println!("  {}", msg);
//!   }

"#
    .to_string()
}

fn emit_imports() -> String {
    "use crate::ir::Domain;\nuse std::collections::{HashMap, HashSet, VecDeque};\n\n"
        .to_string()
}

fn emit_rule(repo_root: &Path, rule: &Fixture) -> Result<String, Box<dyn Error>> {
    match util::attr(rule, "body_strategy") {
        "templated" => emit_templated(rule),
        "embedded" => emit_embedded(repo_root, rule),
        other => Err(format!("unknown body_strategy: {}", other).into()),
    }
}

fn emit_templated(rule: &Fixture) -> Result<String, Box<dyn Error>> {
    match util::attr(rule, "check_kind") {
        "count_threshold" => Ok(emit_count_threshold(rule)),
        other => Err(format!("unknown templated check_kind: {}", other).into()),
    }
}

fn emit_count_threshold(rule: &Fixture) -> String {
    let threshold: i64 = util::attr(rule, "threshold").parse().unwrap_or(0);
    let rust_fn_name = util::attr(rule, "rust_fn_name");
    let message_template = util::attr(rule, "message_template");
    format!(
        "\
/// Returns Some(msg) if the domain has more than {threshold} aggregates.
pub fn {rust_fn_name}(domain: &Domain) -> Option<String> {{
    if domain.aggregates.len() > {threshold} {{
        Some(format!(
            \"{message_template}\",
            domain.name,
            domain.aggregates.len()
        ))
    }} else {{
        None
    }}
}}

",
        threshold = threshold,
        rust_fn_name = rust_fn_name,
        message_template = message_template,
    )
}

fn emit_embedded(repo_root: &Path, rule: &Fixture) -> Result<String, Box<dyn Error>> {
    let snippet_path = repo_root.join(util::attr(rule, "snippet_path"));
    let body = util::read_snippet_body(&snippet_path)?;
    let threshold: i64 = util::attr(rule, "threshold").parse().unwrap_or(0);
    let rust_fn_name = util::attr(rule, "rust_fn_name");
    Ok(format!(
        "\
/// Returns Some(msg) if the domain has {threshold}+ aggregates split across
/// disconnected reference/policy clusters.
pub fn {rust_fn_name}(domain: &Domain) -> Option<String> {{
{body}}}
",
        threshold = threshold,
        rust_fn_name = rust_fn_name,
        body = body,
    ))
}
