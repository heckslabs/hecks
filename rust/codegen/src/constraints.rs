//! Port of `rust/project/constraints.rb` — read that file's own header in
//! full; this mirrors `scalar_field_expr`/`admitted_set_members`/
//! `emit_admits_check`/`emit_pattern_check` directly.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;

/// The scalar `admitted_scalar`/`check_patterns` actually operate on.
pub fn scalar_field_expr(value_expr: &str, attr_type: &str, value_objects_by_name: &std::collections::HashMap<String, &Json>) -> Option<String> {
    if attr_type == "String" {
        return Some(value_expr.to_string());
    }
    let vo = value_objects_by_name.get(attr_type)?;
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if attrs.len() != 1 {
        return None;
    }
    let field = naming::rust_ident_field(crate::attr::name(&attrs[0]));
    Some(format!("{value_expr}.{field}"))
}

/// `"Aggregate::SetName"` resolved against the full domain.
pub fn admitted_set_members(admits: &str, aggregates_by_name: &std::collections::HashMap<String, &Json>) -> Option<Vec<String>> {
    let mut parts = admits.splitn(2, "::");
    let aggregate_name = parts.next()?;
    let set_name = parts.next()?;
    let aggregate = aggregates_by_name.get(aggregate_name)?;
    let vos = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]);
    let vo = vos.iter().find(|v| v.get("name").and_then(Json::as_str) == Some(set_name))?;
    if !vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        return None;
    }
    let members = vo.get("members").map(Json::each).unwrap_or(&[]);
    Some(
        members
            .iter()
            .map(|row| {
                let pairs = row.as_array().unwrap_or(&[]);
                let first = pairs.first().and_then(|pair| pair.as_array()).unwrap_or(&[]);
                first.get(1).map(Json::to_s).unwrap_or_default()
            })
            .collect(),
    )
}

pub fn emit_admits_check(
    exemplar: &Exemplar,
    value_expr: &str,
    attr: &Json,
    aggregates_by_name: &std::collections::HashMap<String, &Json>,
    value_objects_by_name: &std::collections::HashMap<String, &Json>,
) -> Option<String> {
    let admits = crate::attr::admits(attr)?;
    let members = admitted_set_members(admits, aggregates_by_name)?;
    let scalar = scalar_field_expr(value_expr, crate::attr::type_name(attr), value_objects_by_name)?;

    let members_array = format!("[{}]", members.iter().map(|m| naming::ruby_inspect_string(m)).collect::<Vec<_>>().join(", "));
    let prefix = format!(
        "{} admits {} — {} — got ",
        crate::attr::name(attr),
        admits,
        members.iter().map(|m| naming::ruby_inspect_string(m)).collect::<Vec<_>>().join(", ")
    );
    Some(exemplar.render(
        "admits_check",
        &[
            ("[\"tmpl_member_a\", \"tmpl_member_b\"]", members_array),
            ("tmpl_scalar", scalar),
            ("\"tmpl_prefix_text\"", naming::ruby_inspect_string(&prefix)),
        ],
    ))
}

pub fn emit_pattern_check(exemplar: &Exemplar, value_expr: &str, attr: &Json, owner_type_name: &str, value_objects_by_name: &std::collections::HashMap<String, &Json>) -> Option<String> {
    let pattern = crate::attr::pattern(attr)?;
    let scalar = scalar_field_expr(value_expr, crate::attr::type_name(attr), value_objects_by_name)?;

    let prefix = format!("{owner_type_name}.{} must match {pattern}, got ", crate::attr::name(attr));
    Some(exemplar.render(
        "pattern_check",
        &[("\"tmpl_pattern_text\"", naming::ruby_inspect_string(pattern)), ("tmpl_scalar", scalar), ("\"tmpl_prefix_text\"", naming::ruby_inspect_string(&prefix))],
    ))
}
