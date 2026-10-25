//! Interprets declared `query "Name" do ... end` blocks compiled to static `QueryDef` rows.
//! A query outside the compiled subset has no row and is refused by the string-form step.

use super::refusal_wording::UnauthorizedTenantRequiredArgs;
use super::{
    query_comparators::QueryComparator, query_cursor, query_ordering, repository, AggregateScan,
    Json, Refusal,
};

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
    /// `cursor` is declared: `limit` is the page size and the call's `after` names the position.
    pub cursor: bool,
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
pub fn run(
    store: &impl AggregateScan,
    def: &QueryDef,
    args: &Json,
    caller_role: Option<&str>,
) -> Result<Vec<(String, Json)>, Refusal> {
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
                UnauthorizedTenantRequiredArgs {
                    query: auth.query_name,
                    field: auth.tenant_field,
                }
                .render_args(),
            ));
        }
    }

    // Reduced once per condition, as `filter_entries` reduces its operand.
    let wants: Vec<(&QueryCondition, Json)> = def
        .conditions
        .iter()
        .map(|condition| {
            let want = match condition.value {
                QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
                QueryConditionValue::NumericLiteral(n) => Json::Num(n, None),
                QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
            };
            (condition, super::query_comparators::comparable(&want))
        })
        .collect();

    // Every condition is tested against the borrowed row, so only a row that passes them all is
    // cloned. ANDing per row keeps what chaining one filter per condition kept.
    let mut entries: Vec<(String, Json)> = Vec::new();
    let known = store.scan_each(def.aggregate, &mut |id, record| {
        let kept = wants.iter().all(|(c, want)| {
            repository::entry_matches(record, c.field, c.comparator, want, cross_domain)
        });
        if kept {
            entries.push((id.to_string(), record.clone()));
        }
    });
    if !known {
        return Err(Refusal::TypeMismatch(format!(
            "unknown aggregate {:?}",
            def.aggregate
        )));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    entries = super::read_model::apply_reference_hops(
        entries,
        def.reference_hop_conditions,
        args,
        store,
    )?;

    if def.cursor {
        return cursor_rows(entries, def, args);
    }

    Ok(query_ordering::apply(
        entries,
        def.order_by.as_ref(),
        def.offset.as_ref(),
        def.limit.as_ref(),
        args,
    ))
}

/// The ordered rows after the call's `after`, capped at the page size.
fn cursor_rows(
    entries: Vec<(String, Json)>,
    def: &QueryDef,
    args: &Json,
) -> Result<Vec<(String, Json)>, Refusal> {
    let ordered = query_ordering::apply(entries, def.order_by.as_ref(), None, None, args);
    let after = args.get("after").and_then(Json::as_str);
    let mut rows = query_cursor::rows_after(ordered, def.order_by.as_ref(), after)?;
    if let Some(limit) = def.limit.as_ref() {
        rows.truncate(query_ordering::resolve_limit(limit, args));
    }
    Ok(rows)
}

/// One page of a cursor query: its rows, and the token of the page after them.
#[derive(Debug, Clone, PartialEq)]
pub struct Page {
    pub rows: Vec<(String, Json)>,
    /// `None` on the last page.
    pub after: Option<String>,
}

/// `run`, asked for one row past the page: that row proves a next page exists and is not answered.
pub fn run_page(
    store: &impl AggregateScan,
    def: &QueryDef,
    args: &Json,
    caller_role: Option<&str>,
) -> Result<Page, Refusal> {
    let size = def
        .limit
        .as_ref()
        .map_or(0, |limit| query_ordering::resolve_limit(limit, args));
    let widened = QueryDef {
        limit: Some(query_ordering::Limit::Literal(size as i64 + 1)),
        ..*def
    };
    let rows = run(store, &widened, args, caller_role)?;
    let (rows, after) = query_cursor::split_page(rows, def.order_by.as_ref(), size);
    Ok(Page { rows, after })
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

pub fn run_entity(
    store: &impl AggregateScan,
    def: &EntityQueryDef,
    args: &Json,
) -> Result<Vec<Json>, Refusal> {
    let records = store
        .scan(def.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", def.aggregate)))?;

    // One entry per element, keyed by parent id, the `(id, record)` shape `filter_entries` takes.
    let mut entries: Vec<(String, Json)> = Vec::new();
    for (parent_id, record) in records {
        if let Some(elements) = record.get(def.list_field).and_then(Json::as_array) {
            entries.extend(
                elements
                    .iter()
                    .map(|element| (parent_id.clone(), element.clone())),
            );
        }
    }

    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n, None),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        entries = repository::filter_entries(entries, condition.field, condition.comparator, &want);
    }

    // `query_ordering::apply` re-sorts stably by parent id, so identity order survives per parent.
    entries.sort_by(|(parent_a, a), (parent_b, b)| {
        parent_a
            .cmp(parent_b)
            .then_with(|| identity_order(a, b, def.identity_keys))
    });
    let ordered = query_ordering::apply(
        entries,
        def.order_by.as_ref(),
        def.offset.as_ref(),
        def.limit.as_ref(),
        args,
    );

    Ok(ordered
        .into_iter()
        .map(|(parent_id, element)| row_under_parent(def.parent_key, parent_id, element))
        .collect())
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
        (Some(Json::Num(x, _)), Some(Json::Num(y, _))) => {
            x.partial_cmp(y).unwrap_or(Ordering::Equal)
        }
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

#[cfg(test)]
mod cursor_tests {
    use super::*;
    use crate::kernel::query_ordering::{Limit, NullsMode, OrderBy};

    struct Rows(Vec<(String, Json)>);

    impl AggregateScan for Rows {
        fn scan(&self, aggregate: &str) -> Option<Vec<(String, Json)>> {
            (aggregate == "Shop::Item").then(|| self.0.clone())
        }
    }

    fn item(id: &str, rank: i64) -> (String, Json) {
        (id.to_string(), Json::obj(vec![("rank", Json::int(rank))]))
    }

    fn paged() -> QueryDef {
        QueryDef {
            verb: "Shop::Item.Paged",
            aggregate: "Shop::Item",
            conditions: &[],
            reference_hop_conditions: &[],
            order_by: Some(OrderBy {
                field: "rank",
                descending: false,
                nulls: NullsMode::Native,
            }),
            offset: None,
            limit: Some(Limit::Literal(2)),
            cursor: true,
            authorization: None,
        }
    }

    fn walk(store: &Rows) -> Vec<Vec<String>> {
        let (mut pages, mut after) = (Vec::new(), None::<String>);
        loop {
            let args = after.as_deref().map_or_else(
                || Json::obj(vec![]),
                |a| Json::obj(vec![("after", Json::str(a))]),
            );
            let page = run_page(store, &paged(), &args, None).unwrap();
            pages.push(page.rows.iter().map(|(id, _)| id.clone()).collect());
            match page.after {
                Some(next) => after = Some(next),
                None => return pages,
            }
        }
    }

    #[test]
    fn walking_pages_yields_every_row_in_order_with_ties_by_identity() {
        let store = Rows(vec![
            item("b", 1),
            item("a", 2),
            item("d", 2),
            item("c", 2),
            item("e", 3),
        ]);
        assert_eq!(
            walk(&store),
            vec![vec!["b", "a"], vec!["c", "d"], vec!["e"]]
        );
    }

    #[test]
    fn a_page_after_the_last_row_is_empty_with_no_next_position() {
        let store = Rows(vec![item("a", 1)]);
        let token = query_cursor::encode(&Json::int(1), "a");
        let page = run_page(
            &store,
            &paged(),
            &Json::obj(vec![("after", Json::str(token))]),
            None,
        )
        .unwrap();
        assert_eq!(
            page,
            Page {
                rows: vec![],
                after: None
            }
        );
    }
}
