//! Interprets declared `query "Name" do ... end` blocks compiled to static `QueryDef` rows.
//! A query outside the compiled subset has no row and is refused by the string-form step.

use super::refusal_wording::UnauthorizedTenantRequiredArgs;
use super::{query_comparators::QueryComparator, query_ordering, repository, AggregateScan, Json, Refusal};

/// One declared query, compiled.
///
/// `verb` is the qualified "Domain::Aggregate.QueryName"; `aggregate` is the bare
/// "Domain::Aggregate" that `AggregateScan::scan` expects.
#[derive(Debug, Clone, Copy)]
pub struct QueryDef {
    pub verb: &'static str,
    pub aggregate: &'static str,
    pub conditions: &'static [QueryCondition],
    /// `where` clauses that hop through a reference (`customer/status`), after `conditions`.
    pub reference_hop_conditions: &'static [super::read_model::ReferenceHopCondition],
    pub order_by: Option<query_ordering::OrderBy>,
    pub offset: Option<query_ordering::Offset>,
    pub limit: Option<query_ordering::Limit>,
    /// `None` when no `authorize` is declared, or it declares no `tenant:`.
    pub authorization: Option<TenantAuth>,
}

/// `authorize policy, tenant: :field`, mirroring `Runtime::TenantScope.apply`.
///
/// A missing tenant arg refuses `Unauthorized`; otherwise `field == args[tenant]` is ANDed
/// onto the query's conditions at codegen time. `tenant_field` is both the field and the arg key.
#[derive(Debug, Clone, Copy)]
pub struct TenantAuth {
    /// The bare declared query name (not the qualified verb), used as `{query}` in the refusal.
    pub query_name: &'static str,
    pub tenant_field: &'static str,
    /// The `authorize` policy, carried but not enforced: Ruby never reads it either, and enforcing
    /// it here would make Rust refuse queries Ruby answers.
    pub policy: &'static str,
}

/// One where clause, compiled; `value` is what a declared query adds over the ad hoc filter.
#[derive(Debug, Clone, Copy)]
pub struct QueryCondition {
    pub field: &'static str,
    pub comparator: QueryComparator,
    pub value: QueryConditionValue,
}

#[derive(Debug, Clone, Copy)]
pub enum QueryConditionValue {
    /// A wire string baked in at codegen time. Emitted only for string-shaped fields or the
    /// `in`/`contains` comparators, which stringify their argument in Ruby too. Never for
    /// gt/gte/lt/lte.
    Literal(&'static str),
    /// A literal for a field proven numeric at codegen time. Resolves to `Json::Num`, never
    /// `Json::Float`: it is only a comparison operand and is never serialised back out.
    NumericLiteral(f64),
    /// A caller-bound attribute name, read from the call's `args`; a missing key reads as
    /// `Json::Null`, as Ruby's `resolve_query_value` does.
    Arg(&'static str),
}

/// Runs a declared query: chained `filter_entries` per condition (keeping id order), then
/// `query_ordering::apply` for `order_by`/`offset`/`limit`, as Ruby filters then orders.
pub fn run(store: &impl AggregateScan, def: &QueryDef, args: &Json, caller_role: Option<&str>) -> Result<Vec<(String, Json)>, Refusal> {
    run_cross_domain(store, def, args, &[], caller_role)
}

/// `run` with an explicit `cross_domain` search list for `NoneInState` conditions.
///
/// `caller_role` is threaded through for future tenant-policy enforcement and is not yet checked.
pub fn run_cross_domain(
    store: &impl AggregateScan,
    def: &QueryDef,
    args: &Json,
    cross_domain: &[(&str, &dyn AggregateScan)],
    _caller_role: Option<&str>,
) -> Result<Vec<(String, Json)>, Refusal> {
    if let Some(auth) = &def.authorization {
        if args.get(auth.tenant_field).is_none() {
            return Err(Refusal::Unauthorized(
                UnauthorizedTenantRequiredArgs { query: auth.query_name, field: auth.tenant_field }.render_args(),
            ));
        }
    }

    let mut entries = store
        .scan(def.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", def.aggregate)))?;

    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        entries =
            repository::filter_entries_cross_domain(entries, condition.field, condition.comparator, &want, cross_domain);
    }

    entries = super::read_model::apply_reference_hops(entries, def.reference_hop_conditions, args, store)?;

    Ok(query_ordering::apply(entries, def.order_by.as_ref(), def.offset.as_ref(), def.limit.as_ref(), args))
}

/// Finds a query by verb; a linear scan is enough for the small generated `QUERIES` table.
pub fn find<'a>(table: &'a [QueryDef], verb: &str) -> Option<&'a QueryDef> {
    table.iter().find(|def| def.verb == verb)
}

/// A declared entity query (`Domain::Aggregate.Entity.Query`), compiled.
///
/// Mirrors `Runtime::QueryInterpreter#entity_rows`: filter each record's `list_field` elements,
/// order by parent id then identity keys, then apply offset and limit.
#[derive(Debug, Clone, Copy)]
pub struct EntityQueryDef {
    pub verb: &'static str,
    pub aggregate: &'static str,
    /// The aggregate's list attribute holding this entity (`withdrawals`).
    pub list_field: &'static str,
    /// The key each row names its owning record under (`atm_card`).
    pub parent_key: &'static str,
    /// The heads of the entity's `identified_by` paths, in order.
    pub identity_keys: &'static [&'static str],
    pub conditions: &'static [QueryCondition],
    pub order_by: Option<query_ordering::OrderBy>,
    pub offset: Option<query_ordering::Offset>,
    pub limit: Option<query_ordering::Limit>,
}

pub fn find_entity<'a>(table: &'a [EntityQueryDef], verb: &str) -> Option<&'a EntityQueryDef> {
    table.iter().find(|def| def.verb == verb)
}

pub fn run_entity(store: &impl AggregateScan, def: &EntityQueryDef, args: &Json) -> Result<Vec<Json>, Refusal> {
    let records = store
        .scan(def.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", def.aggregate)))?;

    // One entry per element, keyed by parent id, the `(id, record)` shape `filter_entries` takes.
    let mut entries: Vec<(String, Json)> = Vec::new();
    for (parent_id, record) in records {
        if let Some(elements) = record.get(def.list_field).and_then(Json::as_array) {
            entries.extend(elements.iter().map(|element| (parent_id.clone(), element.clone())));
        }
    }

    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        entries = repository::filter_entries(entries, condition.field, condition.comparator, &want);
    }

    // `query_ordering::apply` re-sorts stably by parent id, so identity order survives per parent.
    entries.sort_by(|(parent_a, a), (parent_b, b)| parent_a.cmp(parent_b).then_with(|| identity_order(a, b, def.identity_keys)));
    let ordered = query_ordering::apply(entries, def.order_by.as_ref(), def.offset.as_ref(), def.limit.as_ref(), args);

    Ok(ordered.into_iter().map(|(parent_id, element)| row_under_parent(def.parent_key, parent_id, element)).collect())
}

fn identity_order(a: &Json, b: &Json, keys: &[&str]) -> std::cmp::Ordering {
    keys.iter()
        .map(|key| compare_comparable(comparable(a.get(key)), comparable(b.get(key))))
        .find(|ordering| *ordering != std::cmp::Ordering::Equal)
        .unwrap_or(std::cmp::Ordering::Equal)
}

/// A single-field value object reduces to its one value.
fn comparable(value: Option<&Json>) -> Option<&Json> {
    match value {
        Some(Json::Object(fields)) if fields.len() == 1 => comparable(Some(&fields[0].1)),
        other => other,
    }
}

fn compare_comparable(a: Option<&Json>, b: Option<&Json>) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (a, b) {
        (Some(Json::Num(x)), Some(Json::Num(y))) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
        (Some(Json::Str(x)), Some(Json::Str(y))) => x.cmp(y),
        (None | Some(Json::Null), None | Some(Json::Null)) => Ordering::Equal,
        (None | Some(Json::Null), _) => Ordering::Less,
        (_, None | Some(Json::Null)) => Ordering::Greater,
        _ => Ordering::Equal,
    }
}

/// `{ parent_key => record.id }.merge(element)`: the parent key leads, and an element field of
/// the same name wins its value.
fn row_under_parent(parent_key: &str, parent_id: String, element: Json) -> Json {
    let mut fields = vec![(parent_key.to_string(), Json::Str(parent_id))];
    if let Json::Object(pairs) = element {
        for (key, value) in pairs {
            if key == parent_key {
                fields[0].1 = value;
            } else {
                fields.push((key, value));
            }
        }
    }
    Json::Object(fields)
}
