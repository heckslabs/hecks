//! ir_json - the Hecks IR, rendered in the shape this runtime's interpreter
//! reads.
//!
//! The parser (parser.rs, parse_blocks.rs, parser_helpers.rs, ir.rs,
//! pattern_subset.rs) came over from Hecks WHOLE and unedited. It produces
//! `ir::Domain`, a typed IR far richer than this runtime uses - policies,
//! fixtures, process managers, cadences, queries, views. That richness is not a
//! problem to be trimmed: it is the parser's knowledge, and trimming it would
//! fork it.
//!
//! So nothing upstream is touched. This module is the ONE seam: it reads the
//! typed IR and emits the subset this interpreter understands, which is also
//! exactly the shape the Ruby exporter emits - so bin/parity can diff the two
//! parsers' readings of the same file.
//!
//! When the Rust parser becomes a projection of the Ruby one, this seam is
//! where that lands, and only this file changes.

use crate::ir::{
    Aggregate, Attribute, Command, Direction, Domain, Entity, Lifecycle, MutationOp, Policy,
    ProcessManager, ProcessManagerHandler, Query, Transition, ValueObject, ValueSpec, WhereClause,
    WhereOp,
};
use serde_json::{json, Map, Value};

pub fn domain_to_value(domain: &Domain) -> Value {
    let aggregates: Vec<Value> = domain.aggregates.iter().map(aggregate_to_value).collect();

    let mut domains = Map::new();
    domains.insert(
        domain.name.clone(),
        json!({
            "name": domain.name,
            "vision": optional(&domain.vision),
            "aggregates": aggregates,
            "policies": domain.policies.iter().map(policy_to_value).collect::<Vec<_>>(),
            "process_managers": domain.process_managers.iter()
                .map(process_manager_to_value).collect::<Vec<_>>()
        }),
    );
    Value::Object(domains)
}

fn aggregate_to_value(aggregate: &Aggregate) -> Value {
    json!({
        "name": aggregate.name,
        "description": optional(&aggregate.description),
        "identified_by": aggregate.identified_by.clone().unwrap_or_else(|| "id".to_string()),
        "attributes": aggregate_attributes(aggregate),
        "value_objects": aggregate.value_objects.iter().map(value_object_to_value).collect::<Vec<_>>(),
        "commands": aggregate.commands.iter().map(|c| command_to_value(c, &aggregate.name)).collect::<Vec<_>>(),
        "lifecycle": aggregate.lifecycle.as_ref().map(lifecycle_to_value),
        "entities": aggregate.entities.iter().map(entity_to_value).collect::<Vec<_>>(),
        "queries": aggregate.queries.iter().map(query_to_value).collect::<Vec<_>>()

    })
}

/// An aggregate's fields, INCLUDING the ones its references imply.
///
/// `reference_to Customer` on an aggregate means "this record carries the
/// customer it belongs to, by identity". The Ruby DSL says that by declaring a
/// plain `customer_id` String — a reference IS an attribute, and Evans is
/// explicit that you point at another root by its identity rather than embedding
/// it. The parser keeps references in a separate list, which is a fine internal
/// shape but a different DOCUMENT, so the seam folds them back in where Ruby
/// puts them.
fn aggregate_attributes(aggregate: &Aggregate) -> Vec<Value> {
    let declared = aggregate.attributes.iter().map(attribute_to_value);

    let implied = aggregate.references.iter().map(|reference| {
        json!({
            "name": format!("{}_id", reference.name),
            "type": "String",
            "list": false,
            "default": Value::Null
        })
    });

    implied.chain(declared).collect()
}

/// An identity-bearing member inside the boundary. It declares the same things
/// a root does, minus the boundary itself — so it renders through the same
/// helpers, and gains whatever they gain.
fn entity_to_value(entity: &Entity) -> Value {
    json!({
        "name": entity.name,
        "description": optional(&entity.description),
        "identified_by": optional(&entity.identified_by),
        "attributes": entity.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "commands": entity.commands.iter().map(|c| command_to_value(c, &entity.name)).collect::<Vec<_>>(),
        "queries": entity.queries.iter().map(query_to_value).collect::<Vec<_>>(),
        "lifecycle": entity.lifecycle.as_ref().map(lifecycle_to_value)
    })
}

/// A named read. The Ruby side evaluates its block ONCE against a recorder and
/// keeps data ; the parser here reads the same clauses out of the source text.
/// Neither carries a closure, which is the property that lets both exist.
fn query_to_value(query: &Query) -> Value {
    json!({
        "name": query.name,
        "description": optional(&query.description),
        "attributes": query.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "wheres": query.wheres.iter().map(where_to_value).collect::<Vec<_>>(),
        "order_by": query.order_by.as_ref().map(|o| json!({
            "field": o.field,
            "direction": match o.direction { Direction::Desc => "desc", _ => "asc" }
        })),
        "limit": query.limit.as_ref().map(|l| json!({ "value": l.value }))
    })
}

fn where_to_value(clause: &WhereClause) -> Value {
    json!({
        "field": clause.field,
        "op": match clause.op {
            WhereOp::Eq => "eq",
            WhereOp::Ne => "ne",
            WhereOp::Gt => "gt",
            WhereOp::Gte => "gte",
            WhereOp::Lt => "lt",
            WhereOp::Lte => "lte",
            WhereOp::In => "in",
            WhereOp::Contains => "contains",
            WhereOp::NoneInState => "none_in_state"
        },
        "value": clause.value
    })
}

/// An event arrives, a command fires. The richer reaction shapes the parser can
/// read (with-specs, data guards, fan-out) are NOT rendered : the Ruby side
/// cannot author them, and emitting a field one runtime can never produce would
/// make parity assert agreement about something only one side can say.
fn policy_to_value(policy: &Policy) -> Value {
    json!({
        "name": policy.name,
        "on_event": policy.on_event,
        "trigger_command": policy.trigger_command,
        "target_domain": optional(&policy.target_domain)
    })
}

fn process_manager_to_value(pm: &ProcessManager) -> Value {
    json!({
        "name": pm.name,
        "correlates_by": pm.correlates_by,
        "starts_on": pm.starts_on,
        "ends_on": optional(&pm.ends_on),
        "states": pm.states,
        "handlers": pm.handlers.iter().map(pm_handler_to_value).collect::<Vec<_>>()
    })
}

fn pm_handler_to_value(handler: &ProcessManagerHandler) -> Value {
    json!({
        "event_type": handler.event_type,
        "from_state": handler.from_state,
        "to_state": handler.to_state,
        "dispatches": handler.dispatches.iter().map(|d| json!({
            "command_name": d.command_name,
            "with": d.with_spec.iter()
                .map(|(key, spec)| json!([key, value_spec_text(spec)]))
                .collect::<Vec<_>>()
        })).collect::<Vec<_>>()
    })
}

/// Only the literal/reference text survives — the Ruby recorder stores exactly
/// that, so anything richer would be a field only one runtime can fill.
fn value_spec_text(spec: &ValueSpec) -> String {
    match spec {
        ValueSpec::Literal { value } => value.clone(),
        ValueSpec::FromEvent { name, .. } => name.clone(),
        ValueSpec::FromPm { name, .. } => name.clone(),
        ValueSpec::FromIter { field } => field.clone()
    }
}

/// A state machine on one field.
///
/// The Ruby side keeps `from:` exactly as it was written — a list stays a list —
/// and flattens to one record per (command, to, from) only when it dumps. The
/// parser here already produces the flat form, so nothing needs expanding: this
/// is the shape both sides agree to speak, reached from opposite directions.
fn lifecycle_to_value(lifecycle: &Lifecycle) -> Value {
    json!({
        "field": lifecycle.field,
        "default": lifecycle.default,
        "transitions": lifecycle.transitions.iter().map(transition_to_value).collect::<Vec<_>>()
    })
}

fn transition_to_value(transition: &Transition) -> Value {
    json!({
        "command": transition.command,
        "to_state": transition.to_state,
        "from_state": transition.from_state
    })
}

fn attribute_to_value(attribute: &Attribute) -> Value {
    json!({
        "name": attribute.name,
        "type": attribute.attr_type,
        "list": attribute.list,
        "default": literal(attribute.default.as_deref())
    })
}

fn value_object_to_value(value_object: &ValueObject) -> Value {
    let invariants: Vec<Value> = value_object
        .invariants
        .iter()
        .map(|invariant| {
            json!({
                "description": invariant.name,
                "canonical": canonicalise(&invariant.expression)
            })
        })
        .collect();

    json!({
        "name": value_object.name,
        "attributes": value_object.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "invariants": invariants
    })
}

fn command_to_value(command: &Command, owner: &str) -> Value {
    let givens: Vec<Value> = command
        .givens
        .iter()
        .map(|given| {
            json!({
                "description": optional(&given.message),
                "canonical": canonicalise(&given.expression)
            })
        })
        .collect();

    // A command acting on an existing instance names ITS OWN aggregate ; a
    // creating command names nothing.
    //
    // A reference to a DIFFERENT root is not "act on this" — it is "belongs to
    // that", carried by identity, which is an attribute. Reading both alike is
    // what made Account.Open refuse with "no Account with id …" : a creating
    // command asked to load the thing it was about to create, because it said
    // which customer it was for.
    let references = command
        .references
        .iter()
        .find(|reference| reference.target == owner)
        .map(|reference| Value::String(reference.target.clone()))
        .unwrap_or(Value::Null);

    // Hecks carries a single `emits` ; this runtime carries a list, because a
    // command announcing two facts is a shape worth leaving room for.
    let emits: Vec<Value> = command
        .emits
        .iter()
        .map(|name| Value::String(name.clone()))
        .collect();

    json!({
        "name": command.name,
        "role": optional(&command.role),
        "goal": optional(&command.description),
        "references": references,
        "attributes": command_attributes(command, owner),
        "givens": givens,
        "mutations": command.mutations.iter().map(mutation_to_value).collect::<Vec<_>>(),
        "emits": emits
    })
}

/// A command's inputs, INCLUDING the ones its cross-references imply.
///
/// `reference_to Customer` on `Account.Open` is a value the caller supplies —
/// which customer this account is for — so the Ruby DSL declares it as a plain
/// `customer_id` String. Only a reference to the command's OWN aggregate is
/// the thing it acts on, and that one is carried in `references` rather than
/// here.
fn command_attributes(command: &Command, owner: &str) -> Vec<Value> {
    let implied = command
        .references
        .iter()
        .filter(|reference| reference.target != owner)
        .map(|reference| {
            json!({
                "name": format!("{}_id", reference.name),
                "type": "String",
                "list": false,
                "default": Value::Null
            })
        });

    implied
        .chain(command.attributes.iter().map(attribute_to_value))
        .collect()
}

/// The Hecks IR keeps a mutation's value as SOURCE TEXT, which is what makes
/// the argument-vs-literal distinction survive: a leading `:` is a command
/// argument, a quoted string is a literal. Nothing has to be guessed.
fn mutation_to_value(mutation: &crate::ir::Mutation) -> Value {
    let target = mutation.field.clone();

    if matches!(mutation.operation, MutationOp::Append | MutationOp::AppendUnique) {
        let mut fields = Map::new();
        let body = mutation
            .value
            .trim()
            .trim_start_matches('{')
            .trim_end_matches('}');

        for pair in body.split(',') {
            if let Some((field, argument)) = pair.split_once(':') {
                let argument = argument.trim().trim_start_matches(':').trim();
                if !argument.is_empty() {
                    fields.insert(field.trim().to_string(), Value::String(argument.to_string()));
                }
            }
        }
        return json!({ "target": target, "op": "append", "fields": fields });
    }

    let text = mutation.value.trim();
    let source = if let Some(name) = text.strip_prefix(':') {
        json!({ "kind": "argument", "name": name })
    } else {
        json!({ "kind": "literal", "value": literal(Some(text)) })
    };

    json!({ "target": target, "op": "set", "source": source })
}

/// One meaning, one text. Must agree with the Ruby extractor, which
/// canonicalises what Prism hands back.
fn canonicalise(source: &str) -> String {
    source
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace(".length", ".size")
        .trim()
        .to_string()
}

/// Source text to a typed JSON value: quotes stripped, whole numbers as
/// numbers, true/false as booleans.
fn literal(text: Option<&str>) -> Value {
    let text = match text {
        Some(text) => text.trim(),
        None => return Value::Null,
    };

    if text.len() >= 2 && text.starts_with('"') && text.ends_with('"') {
        return Value::String(text[1..text.len() - 1].to_string());
    }
    if let Ok(number) = text.parse::<i64>() {
        return Value::from(number);
    }
    match text {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        "nil" | "null" | "" => Value::Null,
        other => Value::String(other.to_string()),
    }
}

fn optional(text: &Option<String>) -> Value {
    match text {
        Some(text) => Value::String(text.clone()),
        None => Value::Null,
    }
}
