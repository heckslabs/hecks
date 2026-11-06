//! Which declared queries the generator leaves without a row (`rust/codegen/src/queries.rs`
//! `query_skip_reason`), decided here from the IR alone. A skipped query is refused as "not
//! generated", so the interpreter must skip exactly the same set.

use super::shape::{self, field, hop_plan, items, text_of, ByName, Kind};
use crate::kernel::Json;

/// The comparators a generated row can carry; `none_in_state` has no generated form.
pub fn known_comparator(op: &str) -> bool {
    matches!(
        op,
        "eq" | "ne" | "gt" | "gte" | "lt" | "lte" | "in" | "contains"
    )
}

fn where_skipped(path: &str, op: &str, raw: &str, aggregate: &Json, objects: &ByName) -> bool {
    let kind = shape::kind_of(aggregate, path, objects);
    if kind == Kind::Unknown {
        return true;
    }
    if raw.starts_with(':') {
        return false;
    }
    if raw == "nil" {
        return !matches!(op, "eq" | "ne");
    }
    if !known_comparator(op) {
        return true;
    }
    if matches!(op, "gt" | "gte" | "lt" | "lte") {
        return kind != Kind::Number;
    }
    !matches!(op, "in" | "contains") && kind == Kind::Other
}

fn clause_skipped(clause: &Json, aggregate: &Json, objects: &ByName, aggregates: &ByName) -> bool {
    let path = text_of(clause, "field");
    let (op, raw) = (text_of(clause, "op"), text_of(clause, "value"));
    match hop_plan(aggregate, &path, aggregates) {
        Some(plan) => {
            let target_objects = shape::by_name(plan.final_aggregate, "value_objects");
            where_skipped(
                &plan.inner_field,
                &op,
                &raw,
                plan.final_aggregate,
                &target_objects,
            )
        }
        None => where_skipped(&path, &op, &raw, aggregate, objects),
    }
}

fn plain_integer(raw: &str) -> bool {
    let digits = raw.strip_prefix('-').unwrap_or(raw);
    !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
}

fn bound_skipped(bound: Option<&Json>) -> bool {
    bound.is_some_and(|bound| {
        let raw = text_of(bound, "value");
        !(raw.starts_with(':') || plain_integer(&raw))
    })
}

fn order_skipped(order_by: Option<&Json>, aggregate: &Json, objects: &ByName) -> bool {
    order_by.is_some_and(|order| {
        let kind = shape::kind_of(aggregate, &text_of(order, "field"), objects);
        !matches!(kind, Kind::Text | Kind::Number)
    })
}

fn tenant_of(query: &Json) -> Option<String> {
    field(query, "authorization")
        .and_then(|a| field(a, "tenant"))
        .map(shape::text)
}

fn selects_nothing_with_arguments(query: &Json) -> bool {
    let selects_nothing = ["order_by", "limit", "offset"]
        .iter()
        .all(|key| field(query, key).is_none());
    items(query, "wheres").is_empty()
        && tenant_of(query).is_none()
        && selects_nothing
        && !items(query, "attributes").is_empty()
}

/// Whether the generator emits no row for `query`, declared on `aggregate`.
pub fn query_skipped(
    query: &Json,
    aggregate: &Json,
    objects: &ByName,
    aggregates: &ByName,
) -> bool {
    let extras = ["consistency", "freshness", "inspection"]
        .iter()
        .any(|key| field(query, key).is_some());
    if extras || !items(query, "index_hints").is_empty() || selects_nothing_with_arguments(query) {
        return true;
    }
    if items(query, "wheres")
        .iter()
        .any(|clause| clause_skipped(clause, aggregate, objects, aggregates))
    {
        return true;
    }
    let tenant_skipped = tenant_of(query).is_some_and(|tenant| {
        where_skipped(&tenant, "eq", &format!(":{tenant}"), aggregate, objects)
    });
    tenant_skipped
        || order_skipped(field(query, "order_by"), aggregate, objects)
        || bound_skipped(field(query, "offset"))
        || bound_skipped(field(query, "limit"))
}

/// Whether the generator emits no row for an entity query: it needs a list holding the entity,
/// and declares no `authorize`.
pub fn entity_query_skipped(
    query: &Json,
    entity: &Json,
    holds_list: bool,
    objects: &ByName,
) -> bool {
    !holds_list
        || field(query, "authorization").is_some()
        || query_skipped(query, entity, objects, &ByName::new())
}
