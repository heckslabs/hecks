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
        "no_primitive_envy" => emit_no_primitive_envy(rule),
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

/// Emit the no_primitive_envy rule body. Walks every Aggregate's
/// own attributes plus every command's attributes (skipping
/// value_object and entity inner attributes — those are allowed to
/// hold primitives because the value_object IS the boundary). Flags
/// any attribute whose type is a bare primitive.
///
/// The discipline : at the aggregate / command surface, every
/// attribute reads as a typed domain concept, never as a String /
/// Integer / Float. Wrap primitives in a value_object every time.
fn emit_no_primitive_envy(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// Aggregate and command attributes must use typed value objects, not bare primitives.
/// Primitives belong inside value_object bodies as the storage layer, never at the
/// aggregate or command surface. No exemptions — write a value object every time.
fn {name}(domain: &Domain) -> Vec<String> {{
    const PRIMITIVES: &[&str] = &[
        \"String\", \"Integer\", \"Float\", \"Boolean\", \"Date\", \"DateTime\", \"JSON\",
    ];
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        for attr in &agg.attributes {{
            if PRIMITIVES.contains(&attr.attr_type.as_str()) {{
                errors.push(format!(
                    \"{{}}.{{}} uses primitive type {{}} — wrap it in a value_object so the domain reads as itself, not as a {{}}\",
                    agg.name, attr.name, attr.attr_type, attr.attr_type
                ));
            }}
        }}
        for cmd in &agg.commands {{
            for attr in &cmd.attributes {{
                if PRIMITIVES.contains(&attr.attr_type.as_str()) {{
                    errors.push(format!(
                        \"{{}}.{{}}.{{}} uses primitive type {{}} — wrap it in a value_object so the domain reads as itself, not as a {{}}\",
                        agg.name, cmd.name, attr.name, attr.attr_type, attr.attr_type
                    ));
                }}
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
/// Within an aggregate, no two commands may share the same name.
/// Across aggregates, names may collide ; FQN dispatch (Aggregate.Command)
/// disambiguates and bare-name dispatch errors on ambiguity at resolve
/// time. Per i155 — lifted from global-uniqueness to per-aggregate so
/// the UL doesn't force suffix workarounds when two aggregates share
/// a natural verb (Layout.Plan + Move.Plan, Layout.Apply + Move.Apply).
fn {name}(domain: &Domain) -> Vec<String> {{
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        let mut seen = HashSet::new();
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
