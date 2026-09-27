//! Derives the identity paths of `identified_by`, in both its field form and its
//! `identified_by ValueObject, as: field` form (mirrors `AttributeCollector`).

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// Resolves `identified_by :field` to its scalar identity paths.
///
/// An `id` or `_id`-suffixed name with no matching attribute passes through: the meta-domain
/// identifies by parent ids the judge's replay supplies (mirrors `attribute_collector.rb`).
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

// Runs at the end of the aggregate body because the value object may be declared after
// `identified_by`. Mints the identity attribute at `insert_at`.
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
