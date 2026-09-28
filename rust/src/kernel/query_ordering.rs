// Shared order/offset/limit tail for declared queries and read models, mirroring Ruby's
// `Ports::Query::Ordering.apply` so both callers sort and cap identically.
use super::{query_comparators, Json};

/// A declared `order_by :field, :direction`; `nulls` folds Ruby's separate `nulls` option in here.
#[derive(Debug, Clone, Copy)]
pub struct OrderBy {
    pub field: &'static str,
    pub descending: bool,
    pub nulls: NullsMode,
}

/// Null placement for a declared order; an unrecognized mode reads as `Native`, as in Ruby.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NullsMode {
    Native,
    First,
    Last,
}

/// A declared `limit N`: a literal count, or a caller-bound arg resolved from the call's `args`.
#[derive(Debug, Clone, Copy)]
pub enum Limit {
    Literal(i64),
    Arg(&'static str),
}

/// A declared `offset N`; resolves exactly like `Limit`, so it shares the type.
pub type Offset = Limit;

/// Sorts by id, layers the declared order, then skips `offset` and caps at `limit`.
///
/// The id sort is unconditional so ties, or no declared order, still give a total order.
/// Offset applies before limit, as in SQL `LIMIT n OFFSET m`.
pub fn apply(
    mut rows: Vec<(String, Json)>,
    order_by: Option<&OrderBy>,
    offset: Option<&Offset>,
    limit: Option<&Limit>,
    args: &Json,
) -> Vec<(String, Json)> {
    rows.sort_by(|a, b| a.0.cmp(&b.0));

    if let Some(order_by) = order_by {
        rows = apply_declared_order(rows, order_by);
    }

    if let Some(offset) = offset {
        let n = resolve_limit(offset, args).min(rows.len());
        rows.drain(0..n);
    }

    if let Some(limit) = limit {
        rows.truncate(resolve_limit(limit, args));
    }

    rows
}

// `sort_by` is stable, so the id order from `apply` survives ties without an index tie-break.
fn apply_declared_order(rows: Vec<(String, Json)>, order_by: &OrderBy) -> Vec<(String, Json)> {
    let (mut null_rows, mut valued_rows): (Vec<(String, Json)>, Vec<(String, Json)>) =
        rows.into_iter().partition(|(_, record)| order_key(record, order_by.field) == Json::Null);

    valued_rows.sort_by(|(_, a), (_, b)| compare_comparable(&order_key(a, order_by.field), &order_key(b, order_by.field)));

    if order_by.descending {
        valued_rows.reverse();
        null_rows.reverse();
    }

    match order_by.nulls {
        NullsMode::First => null_rows.into_iter().chain(valued_rows).collect(),
        NullsMode::Last => valued_rows.into_iter().chain(null_rows).collect(),
        NullsMode::Native if !order_by.descending => null_rows.into_iter().chain(valued_rows).collect(),
        NullsMode::Native => valued_rows.into_iter().chain(null_rows).collect(),
    }
}

// Reduced like a where clause's held value; a missing field reads as `Json::Null`.
fn order_key(record: &Json, field: &str) -> Json {
    query_comparators::comparable(&record.dig(field).cloned().unwrap_or(Json::Null))
}

// Codegen only lets a declared field resolve to a number or a string, homogeneous per field.
fn compare_comparable(a: &Json, b: &Json) -> std::cmp::Ordering {
    match (a, b) {
        (Json::Num(x, _) | Json::Float(x), Json::Num(y, _) | Json::Float(y)) => {
            x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal)
        }
        (Json::Str(x), Json::Str(y)) => x.cmp(y),
        _ => std::cmp::Ordering::Equal,
    }
}

// A missing or non-numeric arg reads as 0 (Ruby's `nil.to_i`); negatives floor to 0.
fn resolve_limit(limit: &Limit, args: &Json) -> usize {
    let raw = match limit {
        Limit::Literal(n) => *n,
        Limit::Arg(name) => args.get(name).and_then(Json::as_i64).unwrap_or(0),
    };
    raw.max(0) as usize
}
