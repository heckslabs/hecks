//! An entity is an aggregate nested in an aggregate: it is read with the same sentences and
//! written with the same formatter, so the two are converted to and from one another here.

use crate::ir;

/// The entity an `Entity:` block read as an aggregate stands for, or what it holds that an entity cannot.
pub(super) fn into_entity(inner: ir::Aggregate) -> Result<ir::Entity, &'static str> {
    if !inner.value_objects.is_empty() {
        return Err("an entity holds no value objects of its own; declare them in the aggregate");
    }
    Ok(ir::Entity {
        name: inner.name,
        description: inner.description,
        identified_by: inner.identified_by,
        attributes: inner.attributes,
        commands: inner.commands,
        queries: inner.queries,
        entities: inner.entities,
        preconditions: inner.preconditions,
        invariants: inner.invariants,
        lifecycle: inner.lifecycle,
    })
}

/// The entity as the aggregate the formatter writes.
pub(super) fn as_aggregate(entity: &ir::Entity) -> ir::Aggregate {
    ir::Aggregate {
        name: entity.name.clone(),
        description: entity.description.clone(),
        identified_by: entity.identified_by.clone(),
        attributes: entity.attributes.clone(),
        commands: entity.commands.clone(),
        queries: entity.queries.clone(),
        entities: entity.entities.clone(),
        preconditions: entity.preconditions.clone(),
        invariants: entity.invariants.clone(),
        lifecycle: entity.lifecycle.clone(),
        ..Default::default()
    }
}
