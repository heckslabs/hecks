//! Builds `QueryDef` and `EntityQueryDef` rows from the IR, the rows `rust/codegen` writes as
//! Rust source. A row's strings are leaked once so it is the same `'static` type the generated
//! tables hold and `named_query::run` runs both unchanged.

use super::shape::{self, field, hop_plan, items, text, text_of, ByName};
use crate::kernel::named_query::{EntityQueryDef, QueryDef, TenantAuth};
use crate::kernel::query_comparators::QueryComparator;
use crate::kernel::query_ordering::{Limit, NullsMode, OrderBy};
use crate::kernel::read_model::{HopStep, ReferenceHopCondition};
use crate::kernel::{Json, QueryCondition, QueryConditionValue};

fn leak(text: &str) -> &'static str {
    Box::leak(text.to_string().into_boxed_str())
}

fn leak_slice<T>(rows: Vec<T>) -> &'static [T] {
    Box::leak(rows.into_boxed_slice())
}

fn comparator(op: &str) -> Option<QueryComparator> {
    Some(match op {
        "eq" => QueryComparator::Eq,
        "ne" => QueryComparator::Ne,
        "gt" => QueryComparator::Gt,
        "gte" => QueryComparator::Gte,
        "lt" => QueryComparator::Lt,
        "lte" => QueryComparator::Lte,
        "in" => QueryComparator::In,
        "contains" => QueryComparator::Contains,
        _ => return None,
    })
}

/// The leading integer of `raw`, as Ruby's `String#to_i` reads it.
fn ruby_to_i(raw: &str) -> i64 {
    let trimmed = raw.trim_start();
    let end = trimmed
        .char_indices()
        .take_while(|(at, c)| c.is_ascii_digit() || (*at == 0 && matches!(c, '-' | '+')))
        .count();
    trimmed[..end].parse().unwrap_or(0)
}

fn is_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

fn unescape(inner: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        out.push(match chars.next()? {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            _ => return None,
        });
    }
    Some(out)
}

/// A `where` value read as the generator reads it, or `None` for a literal it would have to
/// spell some other way (a list, a hash, a boolean, a single-quoted or escaped string).
fn condition_value(raw: &str) -> Option<QueryConditionValue> {
    if raw.starts_with(':') {
        return Some(QueryConditionValue::Arg(leak(raw.trim_start_matches(':'))));
    }
    let raw = raw.trim();
    if raw.is_empty() || raw == "nil" {
        return Some(QueryConditionValue::Null);
    }
    let digits = raw.strip_prefix('-').unwrap_or(raw);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        return raw
            .parse::<i64>()
            .ok()
            .map(|n| QueryConditionValue::NumericLiteral(n as f64));
    }
    if matches!(digits.split_once('.'), Some((whole, frac)) if is_digits(whole) && is_digits(frac))
    {
        return raw
            .parse::<f64>()
            .ok()
            .map(QueryConditionValue::NumericLiteral);
    }
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        return unescape(&raw[1..raw.len() - 1]).map(|s| QueryConditionValue::Literal(leak(&s)));
    }
    let bare = !raw.starts_with(['{', '[', '\''])
        && !matches!(raw, "true" | "false")
        && !raw.contains('"');
    bare.then(|| QueryConditionValue::Literal(leak(raw)))
}

fn condition(clause: &Json, path: &str) -> Option<QueryCondition> {
    Some(QueryCondition {
        field: leak(path),
        comparator: comparator(&text_of(clause, "op"))?,
        value: condition_value(&text_of(clause, "value"))?,
    })
}

fn tenant_condition(query: &Json) -> Option<QueryCondition> {
    let tenant = field(query, "authorization")
        .and_then(|a| field(a, "tenant"))
        .map(text)?;
    Some(QueryCondition {
        field: leak(&tenant),
        comparator: QueryComparator::Eq,
        value: QueryConditionValue::Arg(leak(&tenant)),
    })
}

fn hop(domain: &str, plan: &shape::HopPlan, clause: &Json) -> Option<ReferenceHopCondition> {
    let through: Vec<HopStep> = plan
        .through
        .iter()
        .map(|(via, target)| HopStep {
            via_field: leak(via),
            target_aggregate: leak(&format!("{domain}::{target}")),
        })
        .collect();
    let inner = condition(clause, &plan.inner_field)?;
    Some(ReferenceHopCondition {
        via_field: leak(&plan.via_field),
        target_aggregate: leak(&format!("{domain}::{}", plan.target)),
        through: leak_slice(through),
        inner_field: inner.field,
        inner_comparator: inner.comparator,
        inner_value: inner.value,
    })
}

fn order_by(query: &Json) -> Option<OrderBy> {
    let order = field(query, "order_by")?;
    let mode = field(query, "null_semantics")
        .map(|n| text_of(n, "mode"))
        .unwrap_or_default();
    let nulls = match mode.as_str() {
        "first" => NullsMode::First,
        "last" => NullsMode::Last,
        _ => NullsMode::Native,
    };
    Some(OrderBy {
        field: leak(&text_of(order, "field")),
        descending: text_of(order, "direction") == "desc",
        nulls,
    })
}

fn bound(query: &Json, key: &str) -> Option<Limit> {
    let raw = text_of(field(query, key)?, "value");
    Some(raw.strip_prefix(':').map_or_else(
        || Limit::Literal(ruby_to_i(&raw)),
        |arg| Limit::Arg(leak(arg)),
    ))
}

fn authorization(name: &str, query: &Json) -> Option<TenantAuth> {
    let auth = field(query, "authorization")?;
    let tenant = field(auth, "tenant").map(text)?;
    Some(TenantAuth {
        query_name: leak(name),
        tenant_field: leak(&tenant),
        policy: leak(&text_of(auth, "policy")),
    })
}

/// The domain and aggregate a query is declared on, with what its `where` clauses resolve against.
pub struct Scope<'a> {
    pub domain: &'a str,
    pub aggregate: &'a Json,
    pub aggregates: &'a ByName<'a>,
}

/// A declared aggregate query as a row, or `None` when a literal has no generated spelling.
pub fn query_def(scope: &Scope, query: &Json) -> Option<&'static QueryDef> {
    let (domain, aggregate) = (scope.domain, text_of(scope.aggregate, "name"));
    let name = text_of(query, "name");
    let (mut conditions, mut hops) = (Vec::new(), Vec::new());
    for clause in items(query, "wheres") {
        let path = text_of(clause, "field");
        match hop_plan(scope.aggregate, &path, scope.aggregates) {
            Some(plan) => hops.push(hop(domain, &plan, clause)?),
            None => conditions.push(condition(clause, &path)?),
        }
    }
    conditions.extend(tenant_condition(query));
    Some(Box::leak(Box::new(QueryDef {
        verb: leak(&format!("{domain}::{aggregate}.{name}")),
        aggregate: leak(&format!("{domain}::{aggregate}")),
        conditions: leak_slice(conditions),
        reference_hop_conditions: leak_slice(hops),
        order_by: order_by(query),
        offset: bound(query, "offset"),
        limit: bound(query, "limit"),
        cursor: field(query, "cursor").is_some(),
        authorization: authorization(&name, query),
    })))
}

/// A declared entity query as a row held by the aggregate's `list_field`.
pub fn entity_query_def(
    scope: &Scope,
    entity: &Json,
    list_field: &str,
    query: &Json,
) -> Option<&'static EntityQueryDef> {
    let (domain, aggregate) = (scope.domain, text_of(scope.aggregate, "name"));
    let conditions: Option<Vec<QueryCondition>> = items(query, "wheres")
        .iter()
        .map(|clause| condition(clause, &text_of(clause, "field")))
        .collect();
    let keys: Vec<&'static str> = items(entity, "identified_by")
        .iter()
        .map(|path| leak(text(path).split('.').next().unwrap_or("")))
        .collect();
    Some(Box::leak(Box::new(EntityQueryDef {
        verb: leak(&format!(
            "{domain}::{aggregate}.{}.{}",
            text_of(entity, "name"),
            text_of(query, "name")
        )),
        aggregate: leak(&format!("{domain}::{aggregate}")),
        list_field: leak(list_field),
        parent_key: leak(&crate::kernel::read_model::to_snake(&aggregate)),
        identity_keys: leak_slice(keys),
        conditions: leak_slice(conditions?),
        order_by: order_by(query),
        offset: bound(query, "offset"),
        limit: bound(query, "limit"),
    })))
}
