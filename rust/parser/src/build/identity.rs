//! Mirrors `AttributeCollector#resolve_identity_field!`/
//! `#resolve_identity_type!` (`lib/hecks/bluebook/dsl/attribute_collector.rb`)
//! — the two DERIVING forms of `identified_by`:
//!
//!   `identified_by :field, :field_two` — the LIVE form (ADR 0025,
//!                                        "Identity"), one or more.
//!                                        Each field's own already-
//!                                        declared attribute decides the
//!                                        shape: a reference resolves
//!                                        bare (already a scalar); a
//!                                        value object expands all of
//!                                        its recursively scalar leaves
//!                                        in declaration order; a bare
//!                                        primitive resolves unchanged.
//!   `identified_by ValueObject, as: field` — mints a structured field
//!                                        (name is `as:` or
//!                                        `Naming.snake(type)`) and then
//!                                        expands the same recursive
//!                                        scalar leaves beneath it.
//!
//! The inline `identified_by do attribute ... end` form is parsed into a
//! synthesized value object by `parse::parse_identified_by`, then reaches
//! `resolve_identity_type` through exactly the same path as a named value
//! object. That keeps all three identity declarations on one flattening
//! rule and one canonical IR shape.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// `AttributeCollector#resolve_identity_field!` — the bare-field form,
/// `identified_by :field` (one or more, composite identity is their
/// JOIN). `field`'s own already-declared attribute decides the shape:
/// a reference is already a scalar (resolves bare, unchanged) ; a
/// single-field value object auto-unwraps to `field.<that field>` ; a
/// bare primitive resolves unchanged too. A list, or a value object
/// with more than one field, refuses.
///
/// `:id` OR AN `_id`-SUFFIXED NAME WITH NO MATCHING ATTRIBUTE is not a
/// typo to refuse — it is the language's own WALK-PARENT/FALLBACK-
/// IDENTITY convention (the meta-domain's own `Command`/`Entity`/
/// `Aggregate` etc. identify by `owner_id`/`bluebook_id`/`aggregate_id`,
/// supplied by the judge's replay rather than declared locally; bare
/// `:id` is `Instance#materialize_identity!`'s own fallback name made
/// explicit). Mirrors Ruby's own comment on this exact branch,
/// `attribute_collector.rb`.
pub fn resolve_identity_field(
    file: &str,
    line: usize,
    context_name: &str,
    field: &str,
    value_objects: &[ir::ValueObject],
    attributes: &[ir::Attribute],
) -> ParseResult<Vec<String>> {
    let attr = attributes.iter().find(|a| a.name == field);

    let attr = match attr {
        Some(attr) => attr,
        None if field == "id" || field.ends_with("_id") => return Ok(vec![field.to_string()]),
        None => {
            return Err(Diagnostic::new(file, line, format!("{context_name}.identified_by :{field} names no attribute {context_name} declares")));
        }
    };

    identity_paths_for_attribute(file, line, context_name, attr, value_objects, field, &[])
}

/// `AttributeCollector#resolve_identity_type!` — `identified_by
/// ValueObject, as: field`. Confirmed real: pizzas.bluebook's own
/// `identified_by PizzaName, as: :name` (line 8), resolved at the END of
/// the aggregate's body (mirroring Ruby's own build-time deferral —
/// `PizzaName` is declared LATER in the file, after `identified_by`
/// itself), not at the point `identified_by` was written.
///
/// Mints the identity attribute at `insert_at` (the attribute count AT
/// THE MOMENT `identified_by` was called — 0 for pizzas.bluebook, since
/// it is the very first line of the aggregate body) and returns the
/// recursively derived identity paths beneath the minted field.
#[allow(clippy::too_many_arguments)]
pub fn resolve_identity_type(
    file: &str,
    line: usize,
    context_name: &str,
    target: &str,
    as_field: Option<&str>,
    insert_at: usize,
    value_objects: &[ir::ValueObject],
    attributes: &mut Vec<ir::Attribute>,
) -> ParseResult<Vec<String>> {
    let target = crate::build::naming::demodulise(target);
    let matches: Vec<&ir::ValueObject> =
        value_objects.iter().filter(|v| v.name == target).collect();
    if matches.len() > 1 {
        return Err(Diagnostic::new(
            file,
            line,
            format!("{context_name}.identified_by names duplicate value object {target}"),
        ));
    }
    let vo = matches.first().copied().ok_or_else(|| {
        Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}.identified_by names {target}, which is not a declared value object"
            ),
        )
    })?;

    if vo.attributes.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("{context_name}.identified_by names {target}, which declares no attributes"),
        ));
    }

    let field = as_field
        .map(|s| s.to_string())
        .unwrap_or_else(|| crate::build::naming::snake(&target));
    if attributes.iter().any(|attribute| attribute.name == field) {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}.identified_by {target} mints :{field}, but that attribute is already declared"
            ),
        ));
    }

    let minted = ir::Attribute {
        name: field.clone(),
        type_name: target.clone(),
        list: false,
        ..Default::default()
    };
    let insert_at = insert_at.min(attributes.len());
    attributes.insert(insert_at, minted);

    let mut paths = Vec::new();
    for attribute in &vo.attributes {
        paths.extend(identity_paths_for_attribute(
            file,
            line,
            context_name,
            attribute,
            value_objects,
            &format!("{field}.{}", attribute.name),
            std::slice::from_ref(&target),
        )?);
    }
    Ok(paths)
}

fn identity_paths_for_attribute(
    file: &str,
    line: usize,
    context_name: &str,
    attribute: &ir::Attribute,
    value_objects: &[ir::ValueObject],
    path: &str,
    visited: &[String],
) -> ParseResult<Vec<String>> {
    if attribute.list {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}'s identity member {path} is a list — an identity member must be scalar"
            ),
        ));
    }
    if attribute.optional {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}'s identity member {path} is optional — an identity must be wholly known"
            ),
        ));
    }
    if attribute.reference_target().is_some() {
        return Ok(vec![path.to_string()]);
    }

    let Some(nested) = value_objects
        .iter()
        .find(|value_object| value_object.name == attribute.type_name)
    else {
        return Ok(vec![path.to_string()]);
    };

    if visited.iter().any(|name| name == &nested.name) {
        let mut cycle = visited.to_vec();
        cycle.push(nested.name.clone());
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}'s identity value objects form a cycle: {}",
                cycle.join(" -> ")
            ),
        ));
    }
    if nested.attributes.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}'s identity member {path} names {}, which declares no attributes",
                nested.name
            ),
        ));
    }

    let mut next_visited = visited.to_vec();
    next_visited.push(nested.name.clone());
    let mut paths = Vec::new();
    for member in &nested.attributes {
        paths.extend(identity_paths_for_attribute(
            file,
            line,
            context_name,
            member,
            value_objects,
            &format!("{path}.{}", member.name),
            &next_visited,
        )?);
    }
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_a_single_path_from_a_one_field_value_object() {
        let mut attributes = vec![ir::Attribute {
            name: "pizza".to_string(),
            type_name: "Pizza".to_string(),
            ..Default::default()
        }];
        let value_objects = vec![ir::ValueObject {
            name: "PizzaName".to_string(),
            attributes: vec![ir::Attribute {
                name: "value".to_string(),
                type_name: "String".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        }];

        let paths = resolve_identity_type(
            "f.bluebook",
            1,
            "Order",
            "PizzaName",
            Some("name"),
            0,
            &value_objects,
            &mut attributes,
        )
        .unwrap();

        assert_eq!(paths, vec!["name.value".to_string()]);
        assert_eq!(attributes[0].name, "name");
        assert_eq!(attributes[0].type_name, "PizzaName");
        assert_eq!(attributes[1].name, "pizza");
    }

    #[test]
    fn expands_every_recursively_scalar_member_in_declaration_order() {
        let mut attributes = Vec::new();
        let value_objects = vec![
            ir::ValueObject {
                name: "BranchCode".to_string(),
                attributes: vec![ir::Attribute {
                    name: "value".to_string(),
                    type_name: "String".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
            ir::ValueObject {
                name: "BoxIdentity".to_string(),
                attributes: vec![
                    ir::Attribute {
                        name: "branch".to_string(),
                        type_name: "BranchCode".to_string(),
                        ..Default::default()
                    },
                    ir::Attribute {
                        name: "number".to_string(),
                        type_name: "Integer".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            },
        ];

        let paths = resolve_identity_type(
            "f.bluebook",
            1,
            "SafeDepositBox",
            "BoxIdentity",
            Some("location"),
            0,
            &value_objects,
            &mut attributes,
        )
        .unwrap();

        assert_eq!(
            paths,
            vec![
                "location.branch.value".to_string(),
                "location.number".to_string()
            ]
        );
        assert_eq!(attributes[0].name, "location");
        assert_eq!(attributes[0].type_name, "BoxIdentity");
    }

    #[test]
    fn rejects_non_scalar_identity_members() {
        let mut attributes = Vec::new();
        let value_objects = vec![ir::ValueObject {
            name: "Identity".to_string(),
            attributes: vec![ir::Attribute {
                name: "regions".to_string(),
                type_name: "String".to_string(),
                list: true,
                ..Default::default()
            }],
            ..Default::default()
        }];

        let error = resolve_identity_type(
            "f.bluebook",
            1,
            "Account",
            "Identity",
            None,
            0,
            &value_objects,
            &mut attributes,
        )
        .unwrap_err();

        assert!(error
            .message
            .contains("identity member identity.regions is a list"));
    }
}
