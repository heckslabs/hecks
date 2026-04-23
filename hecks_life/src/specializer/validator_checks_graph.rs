//! Graph-traversal check emitters for the `validator` Phase D port.
//!
//! The three `check_kind`s in this file each walk the cross-aggregate
//! graph to detect constraint violations:
//!
//!   reference_valid   — every `reference_to(X)` must resolve to a
//!                        declared aggregate in the same domain
//!   trigger_valid     — every policy's `trigger_command` must match
//!                        a command declared in the same domain
//!   distinct_aliases  — multiple references to the same target must
//!                        carry distinct `as:` aliases
//!
//! Split out from `validator_checks.rs` so neither file crosses the
//! 200-LoC cap. The parent `validator_checks::emit_rule` dispatches
//! in; each emitter here is pub(super) so only sibling modules in
//! `specializer::` can call them.
//!
//! Byte-identity policy — identical to sibling emitters: every
//! `format!` body reproduces the Ruby heredoc text character for
//! character.
//!
//! Usage:
//!   let text = emit_reference_valid(rule);
//!
//! [antibody-exempt: hecks_life/src/specializer/validator_checks_graph.rs —
//!  Phase D — Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;

pub(super) fn emit_reference_valid(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// References must target existing aggregate roots.
fn {name}(domain: &Domain) -> Vec<String> {{
    let agg_names: HashSet<&str> = domain
        .aggregates
        .iter()
        .map(|a| a.name.as_str())
        .collect();

    let mut errors = vec![];
    for agg in &domain.aggregates {{
        for reference in &agg.references {{
            if reference.domain.is_some() {{
                continue; // cross-domain refs validated elsewhere
            }}
            if !agg_names.contains(reference.target.as_str()) {{
                errors.push(format!(
                    \"{{}} references unknown aggregate: {{}}\",
                    agg.name, reference.target
                ));
            }}
        }}
        for cmd in &agg.commands {{
            for reference in &cmd.references {{
                if reference.domain.is_some() {{
                    continue;
                }}
                if !agg_names.contains(reference.target.as_str()) {{
                    errors.push(format!(
                        \"Command {{}} references unknown aggregate: {{}}\",
                        cmd.name, reference.target
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

pub(super) fn emit_trigger_valid(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// Policy triggers must name existing commands.
fn {name}(domain: &Domain) -> Vec<String> {{
    let all_commands: HashSet<&str> = domain
        .aggregates
        .iter()
        .flat_map(|a| a.commands.iter().map(|c| c.name.as_str()))
        .collect();

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none()) // skip cross-domain
        .filter(|p| !all_commands.contains(p.trigger_command.as_str()))
        .map(|p| {{
            format!(
                \"Policy {{}} triggers unknown command: {{}}\",
                p.name, p.trigger_command
            )
        }})
        .collect()
}}

"
    )
}

pub(super) fn emit_distinct_aliases(rule: &Fixture) -> String {
    let name = util::attr(rule, "rust_fn_name");
    format!(
        "\
/// When an aggregate has multiple reference_to the same target,
/// each must carry a distinct `as:` alias — otherwise the references
/// share the same `name` and downstream consumers (event payloads,
/// generated form fields, dispatch routing) can't tell them apart.
fn {name}(domain: &Domain) -> Vec<String> {{
    let mut errors = vec![];
    for agg in &domain.aggregates {{
        // Group references by (target, name). Any group with size > 1
        // is a collision: multiple references share the same alias.
        let mut groups: std::collections::BTreeMap<(&str, &str), usize> =
            std::collections::BTreeMap::new();
        for r in &agg.references {{
            *groups.entry((r.target.as_str(), r.name.as_str())).or_insert(0) += 1;
        }}
        for ((target, name), count) in &groups {{
            if *count > 1 {{
                errors.push(format!(
                    \"{{}} has {{}} references to {{}} with duplicate alias {{:?}} — add `as: :<alias>` to each so they have distinct names\",
                    agg.name, count, target, name
                ));
            }}
        }}
    }}
    errors
}}
"
    )
}
