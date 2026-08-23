//! Query-input inference after the chapter's aggregate graph is complete.
//! A symbolic `where` operand is an input whose type is already determined
//! by the compared field. Local bare/dotted paths resolve against their
//! owner immediately; `/` reference hops resolve here, after every target
//! aggregate exists. Pagination symbols have no compared field and therefore
//! remain explicit declarations.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::ruby_value;

pub fn apply(file: &str, bluebook: &mut ir::Bluebook) -> ParseResult<()> {
    let shapes = bluebook.aggregates.clone();

    for aggregate in &mut bluebook.aggregates {
        let owner = shapes
            .iter()
            .find(|candidate| candidate.name == aggregate.name)
            .expect("aggregate cloned from the same chapter");

        infer_queries(
            file,
            &aggregate.name,
            &mut aggregate.queries,
            &owner.attributes,
            owner.lifecycle.as_ref(),
            &owner.value_objects,
            Some((owner, &shapes)),
        )?;

        for entity in &mut aggregate.entities {
            let entity_shape = owner
                .entities
                .iter()
                .find(|candidate| candidate.name == entity.name)
                .expect("entity cloned from the same aggregate");
            infer_queries(
                file,
                &format!("{}::{}", aggregate.name, entity.name),
                &mut entity.queries,
                &entity_shape.attributes,
                entity_shape.lifecycle.as_ref(),
                &owner.value_objects,
                None,
            )?;
        }
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn infer_queries(
    file: &str,
    owner_name: &str,
    queries: &mut [ir::Query],
    attributes: &[ir::Attribute],
    lifecycle: Option<&ir::Lifecycle>,
    value_objects: &[ir::ValueObject],
    hop_context: Option<(&ir::Aggregate, &[ir::Aggregate])>,
) -> ParseResult<()> {
    for query in queries {
        let clauses = query.wheres.clone();

        // Ruby resolves every local field while its aggregate is sealed, then
        // resolves reference hops after the chapter exists. Keep those phases
        // distinct so inferred arguments retain the same order even when a
        // query writes a hop before a local comparison.
        for clause in &clauses {
            if clause.field.contains('/') {
                continue;
            }
            let Some(argument_name) = symbolic_name(&clause.value) else {
                continue;
            };
            let leaf = local_leaf(attributes, lifecycle, value_objects, &clause.field);
            if let Some(leaf) = leaf {
                append_unless_declared(query, &argument_name, leaf);
            }
        }

        if let Some((owner, aggregates)) = hop_context {
            for clause in &clauses {
                if !clause.field.contains('/') {
                    continue;
                }
                let Some(argument_name) = symbolic_name(&clause.value) else {
                    continue;
                };
                if let Some(leaf) = hop_leaf(owner, aggregates, &clause.field) {
                    append_unless_declared(query, &argument_name, leaf);
                }
            }
        }

        for clause in &query.wheres {
            require_declared_symbol(file, owner_name, query, &clause.value)?;
        }
        if let Some(limit) = &query.limit {
            require_declared_symbol(file, owner_name, query, &limit.value)?;
        }
        if let Some(offset) = &query.options.offset {
            require_declared_symbol(file, owner_name, query, offset)?;
        }
    }

    Ok(())
}

fn append_unless_declared(query: &mut ir::Query, name: &str, leaf: ir::Attribute) {
    if !query
        .attributes
        .iter()
        .any(|attribute| attribute.name == name)
    {
        query.attributes.push(inferred_attribute(name, leaf));
    }
}

fn symbolic_name(rendered: &str) -> Option<String> {
    match ruby_value::read(rendered) {
        ruby_value::Value::Symbol(name) => Some(name),
        _ => None,
    }
}

fn require_declared_symbol(
    file: &str,
    owner_name: &str,
    query: &ir::Query,
    rendered: &str,
) -> ParseResult<()> {
    let Some(name) = symbolic_name(rendered) else {
        return Ok(());
    };
    if query
        .attributes
        .iter()
        .any(|attribute| attribute.name == name)
    {
        return Ok(());
    }

    Err(Diagnostic::new(
        file,
        0,
        format!(
            "{owner_name}.{} resolves :{name} from its arguments, but declares no {name} attribute",
            query.name
        ),
    ))
}

fn local_leaf(
    attributes: &[ir::Attribute],
    lifecycle: Option<&ir::Lifecycle>,
    value_objects: &[ir::ValueObject],
    path: &str,
) -> Option<ir::Attribute> {
    let mut segments = path.split('.');
    let head = segments.next()?;
    let nested: Vec<&str> = segments.collect();

    if nested.is_empty() && lifecycle.is_some_and(|held| held.field == head) {
        return Some(ir::Attribute {
            name: head.to_string(),
            type_name: "String".to_string(),
            ..Default::default()
        });
    }

    let mut current = attributes.iter().find(|attribute| attribute.name == head)?;
    for member_name in nested {
        let value_object = value_objects
            .iter()
            .find(|value_object| value_object.name == current.type_name)?;
        current = value_object
            .attributes
            .iter()
            .find(|attribute| attribute.name == member_name)?;
    }
    Some(current.clone())
}

fn hop_leaf(
    owner: &ir::Aggregate,
    aggregates: &[ir::Aggregate],
    path: &str,
) -> Option<ir::Attribute> {
    let segments: Vec<&str> = path.split('/').collect();
    let (tail, hops) = segments.split_last()?;
    if hops.is_empty() || tail.is_empty() {
        return None;
    }

    let mut target = owner;
    for hop in hops {
        let reference = target
            .attributes
            .iter()
            .find(|attribute| attribute.name == *hop)?;
        let target_name = reference.reference_target()?;
        target = aggregates.iter().find(|aggregate| {
            aggregate.name == target_name
                || aggregate.name.rsplit("::").next() == target_name.rsplit("::").next()
        })?;
    }

    local_leaf(
        &target.attributes,
        target.lifecycle.as_ref(),
        &target.value_objects,
        tail,
    )
}

fn inferred_attribute(name: &str, leaf: ir::Attribute) -> ir::Attribute {
    ir::Attribute {
        name: name.to_string(),
        type_name: leaf.type_name,
        list: leaf.list,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pagination_symbols_are_not_inferred_without_a_compared_field() {
        let cases = [
            (
                ir::Query {
                    name: "Page".to_string(),
                    limit: Some(ir::LimitSpec {
                        value: ":page_size".to_string(),
                    }),
                    ..Default::default()
                },
                "page_size",
            ),
            (
                ir::Query {
                    name: "Page".to_string(),
                    options: ir::QueryOptions {
                        offset: Some(":start_at".to_string()),
                        ..Default::default()
                    },
                    ..Default::default()
                },
                "start_at",
            ),
        ];

        for (mut query, missing) in cases {
            let refusal = infer_queries(
                "fixture.bluebook",
                "Item",
                std::slice::from_mut(&mut query),
                &[],
                None,
                &[],
                None,
            )
            .unwrap_err();

            assert!(refusal
                .to_string()
                .contains(&format!("declares no {missing} attribute")));
            assert!(query.attributes.is_empty());
        }
    }
}
