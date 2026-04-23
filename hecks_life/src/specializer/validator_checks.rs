//! Local check-kind emitters for the `validator` Phase D port.
//!
//! Owns the four single-aggregate emitters and dispatches to the
//! graph-traversal trio living in `validator_checks_graph.rs`:
//!
//!   this file                     — unique | non_empty |
//!                                    first_word_verb | unique_across
//!   validator_checks_graph.rs     — reference_valid | trigger_valid |
//!                                    distinct_aliases
//!   validator_morphology.rs       — command_naming_support + suffix
//!                                    / verb-exception / verb-suffix
//!                                    formatters
//!
//! Byte-identity policy — every `format!` block here reproduces the
//! Ruby `Hecks::Specializer::Validator` heredoc output character for
//! character.
//!
//! Usage:
//!   let text = emit_rule(&fixtures, rule);
//!
//! [antibody-exempt: hecks_life/src/specializer/validator_checks.rs —
//!  Phase D — Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use crate::specializer::validator_checks_graph as graph;

/// Dispatch a single `ValidationRule` fixture row to its emitter.
pub fn emit_rule(_fixtures: &[Fixture], rule: &Fixture) -> String {
    match util::attr(rule, "check_kind") {
        "unique" => emit_unique(rule),
        "non_empty" => emit_non_empty(rule),
        "first_word_verb" => emit_first_word_verb(rule),
        "unique_across" => emit_unique_across(rule),
        "reference_valid" => graph::emit_reference_valid(rule),
        "trigger_valid" => graph::emit_trigger_valid(rule),
        "distinct_aliases" => graph::emit_distinct_aliases(rule),
        other => panic!("unknown check_kind: {}", other),
    }
}

fn emit_unique(rule: &Fixture) -> String {
    let description = util::attr(rule, "description");
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// {description}.
fn {name}(domain: &Domain) -> Vec<String> {{
    let mut seen = HashSet::new();
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        if !seen.insert(&agg.name) {{
            errors.push(format!(\"Duplicate aggregate name: {{}}\", agg.name));
        }}
    }}
    errors
}}

"
    )
}

fn emit_non_empty(rule: &Fixture) -> String {
    let description = util::attr(rule, "description");
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// {description}.
fn {name}(domain: &Domain) -> Vec<String> {{
    domain
        .aggregates
        .iter()
        .filter(|a| a.commands.is_empty())
        .map(|a| format!(\"{{}} has no commands\", a.name))
        .collect()
}}

"
    )
}

fn emit_first_word_verb(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
fn {name}(domain: &Domain) -> Vec<String> {{
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        for cmd in &agg.commands {{
            let word = first_word(&cmd.name);
            if is_not_verb(&word) {{
                errors.push(format!(
                    \"Command {{}} in {{}} starts with '{{}}' which looks like a {{}} — commands should start with a verb\",
                    cmd.name, agg.name, word,
                    if NOUN_SUFFIXES.iter().any(|s| word.to_lowercase().ends_with(s)) {{ \"noun\" }} else {{ \"adjective\" }}
                ));
            }}
        }}
    }}
    errors
}}

"
    )
}

fn emit_unique_across(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// No two commands across all aggregates should share the same name.
fn {name}(domain: &Domain) -> Vec<String> {{
    let mut seen = HashSet::new();
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        for cmd in &agg.commands {{
            if !seen.insert(&cmd.name) {{
                errors.push(format!(
                    \"Duplicate command name: {{}} (in {{}})\",
                    cmd.name, agg.name
                ));
            }}
        }}
    }}
    errors
}}

"
    )
}
