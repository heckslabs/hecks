// EXTRACTED FROM `kernel/read_model.rs` (2026-08-11), NOT REINVENTED — this
// was `apply_declared_order`/`resolve_limit`/`order_key`/`compare_comparable`
// plus the TIER-1-identity/TIER-2-declared-order shape of `apply_filtered_
// head_options`, moved here unchanged so `kernel/named_query.rs` can call
// the SAME code for a declared AGGREGATE query's own `order_by`/`limit`
// rather than growing a second, drifting copy. `read_model.rs`'s own
// header used to say (before this extraction) "no existing kernel
// capability sorts at all... so this is a new, hand-written shape" — that
// was true the day it was written and is exactly what made it new; it
// stopped being true the moment a second caller needed the identical
// logic, which is what this file is for.
//
// GROUND TRUTH — read directly, not assumed identical between callers:
//
//   `Runtime::QueryInterpreter#interpret` (lib/hecks/runtime/
//   query_interpreter.rb) — a declared AGGREGATE query's own path:
//   `ordered = ordered(matched, declared.order_by, declared.null_semantics)`
//   then `capped = declared.limit ? ordered.first(resolve_query_value(
//   declared.limit.value, args).to_i) : ordered`. `ordered` itself is
//   `Ports::Query::Ordering.apply(records, order_by, null_semantics,
//   identity: ->(record) { record.id.to_s }) { |record| comparable(record
//   [field]) }` — id-string identity, exactly what `apply` below sorts by
//   in its own TIER 1.
//
//   `Ports::Query::InMemory.execute` (lib/hecks/ports/query/
//   in_memory.rb) — the read model's own path (`ReadModelInterpreter#
//   project` calls this for the one eligible head): `matched = Ordering.
//   apply(matched, declared.order_by, declared.null_semantics, identity:
//   ->(record) { record.id.to_s }) { comparable(FieldPath.dig(record,
//   field)) }` then `matched.first(resolve(declared.limit.value, args).
//   to_i) if declared.limit`. IDENTICAL shape to `interpret` above —
//   same `Ordering.apply` call, same id-string identity block, same
//   `.first(N)` capping (`Vec::truncate` here is `Array#first`'s own
//   effect on an owned, already-sorted Vec: keep the first N, drop the
//   rest — the two are the same operation read from opposite ends).
//
// THE ONE REAL STRUCTURAL DIFFERENCE BETWEEN THE TWO CALLERS, confirmed by
// reading both interpreters rather than assumed: a declared query has NO
// `filtered_head` concept at all — `interpret` orders/caps its OWN single
// matched set directly, because a query never chooses among several
// aggregate heads the way a read model's `report` block does. `read_model.
// rs`'s `apply_filtered_head_options` calls `apply` below on ONE head's
// own rows (the one `filtered_head` names); `named_query.rs`'s `run` calls
// it on the query's own (only) result set. Everything AFTER that
// selection — identity sort, declared order, limit — is the same function,
// because Ruby's own `Ordering.apply`/`.first(N)` never knew or cared
// which caller it was serving either.
use super::{query_comparators, Json};

/// A declared `order_by :field, :direction` — `field`/`direction` read
/// exactly like `QuerySpecification::Common::OrderBy` (lib/hecks/
/// query_specification/common/order_by.rb); `descending` collapses Ruby's
/// own `direction.to_s == "desc"` test to a bool once, at codegen time,
/// rather than re-testing a string on every row compared.
#[derive(Debug, Clone, Copy)]
pub struct OrderBy {
    pub field: &'static str,
    pub descending: bool,
}

/// A declared `limit N` — either a literal count baked in at codegen
/// time, or a caller-bound Symbol arg resolved from THIS call's own wire
/// `args` at dispatch time, the identical Literal/Arg split `named_query::
/// QueryConditionValue` already draws for a where clause's own value.
/// Ground truth: `Ports::Query::InMemory.execute`'s own `resolve(declared.
/// limit.value, args).to_i` / `QueryInterpreter#interpret`'s own
/// `resolve_query_value(declared.limit.value, args).to_i` — the SAME
/// resolution both callers this module serves already agree on.
#[derive(Debug, Clone, Copy)]
pub enum Limit {
    Literal(i64),
    Arg(&'static str),
}

/// THE SHARED TAIL of both callers' own answer: sort by identity, layer a
/// declared order on top if there is one, cap at a declared limit if
/// there is one. Where-FILTERING happens before this runs and is each
/// caller's own job (`repository::filter_entries`, chained per condition
/// — identical in both `read_model::apply_filtered_head_options` and
/// `named_query::run`, so there was nothing to extract there; the
/// dedicated logic to a query/read model was never the filtering, it was
/// always this tail).
///
/// TIER 1 — IDENTITY. `Ports::Query::Ordering.apply`'s own header: "the
/// identity tier is what makes an ask total" — every answer is sorted by
/// id ascending FIRST, order_by declared or not, so a tie in the declared
/// order (or the total absence of one) still has a total, deterministic
/// answer rather than leaking whatever order the store happened to hold.
/// Kept unconditional (not skipped when `order_by`/`limit` are both
/// `None`) for the same reason `read_model.rs`'s own predecessor of this
/// function kept it unconditional: a caller with `conditions`/`wheres`
/// already re-sorts by id on every `filter_entries` step, so this is a
/// no-op then, but a caller declaring ONLY `order_by`/`limit` (no `where`
/// at all) still needs the same identity base Ruby's own two-tier scheme
/// guarantees on every path.
pub fn apply(mut rows: Vec<(String, Json)>, order_by: Option<&OrderBy>, limit: Option<&Limit>, args: &Json) -> Vec<(String, Json)> {
    rows.sort_by(|a, b| a.0.cmp(&b.0));

    if let Some(order_by) = order_by {
        rows = apply_declared_order(rows, order_by);
    }

    if let Some(limit) = limit {
        rows.truncate(resolve_limit(limit, args));
    }

    rows
}

/// TIER 2 — the declared order, layered on top of the identity base `rows`
/// already carries in. `QuerySpecification::Common::NullPolicy.order`,
/// ported directly: partition into null/valued by the declared field's own
/// `comparable`-reduced value; sort the valued partition by that value
/// (Rust's `Vec::sort_by` is STABLE — unlike Ruby's `Array#sort_by` — so the
/// identity order the caller already established survives ties for free,
/// with no index tie-break to carry along by hand the way Ruby's own
/// `NullPolicy.order` has to); reverse BOTH partitions for `desc`; then
/// combine under the DEFAULT ("native") null policy — the only one either
/// generator calling into this admits (`read_models.rb`'s own eligibility
/// gate, `queries.rb`'s own, both refuse a declared `null_semantics`
/// beyond it) — which is `NullPolicy.order`'s own `else` arm: nulls sort
/// FIRST for ascending, LAST for descending.
fn apply_declared_order(rows: Vec<(String, Json)>, order_by: &OrderBy) -> Vec<(String, Json)> {
    let (mut null_rows, mut valued_rows): (Vec<(String, Json)>, Vec<(String, Json)>) =
        rows.into_iter().partition(|(_, record)| order_key(record, order_by.field) == Json::Null);

    valued_rows.sort_by(|(_, a), (_, b)| compare_comparable(&order_key(a, order_by.field), &order_key(b, order_by.field)));

    if !order_by.descending {
        return null_rows.into_iter().chain(valued_rows).collect();
    }
    valued_rows.reverse();
    null_rows.reverse();
    valued_rows.into_iter().chain(null_rows).collect()
}

/// A row's own declared-field value, `comparable`-reduced exactly like a
/// where clause's held value already is (`query_comparators::comparable`,
/// reused rather than reimplemented) — a missing field digs to `Json::Null`,
/// matching `FieldPath.dig`'s own miss-is-nil reading.
fn order_key(record: &Json, field: &str) -> Json {
    query_comparators::comparable(&record.dig(field).cloned().unwrap_or(Json::Null))
}

/// `Array#<=>`'s own definition, narrowed to the two kinds either
/// generator calling into this module ever lets a declared order_by field
/// resolve to — a JSON number or a JSON string, always homogeneous within
/// one declared field (the same aggregate's same attribute on every row):
/// codegen refuses anything else (a hop, a `list_of` field, a multi-member
/// non-numeric value object) before this can ever run, so the two
/// exhaustive arms below are the only ones a real generated `OrderBy` can
/// ever actually reach.
fn compare_comparable(a: &Json, b: &Json) -> std::cmp::Ordering {
    match (a, b) {
        (Json::Num(x) | Json::Float(x), Json::Num(y) | Json::Float(y)) => {
            x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal)
        }
        (Json::Str(x), Json::Str(y)) => x.cmp(y),
        _ => std::cmp::Ordering::Equal,
    }
}

/// `Ports::Query::InMemory.execute`'s own `resolve(declared.limit.value,
/// args).to_i` / `QueryInterpreter#interpret`'s own `resolve_query_value(
/// declared.limit.value, args).to_i`, ported: a literal count rides
/// straight through; a Symbol arg resolves from THIS call's own wire
/// `args`, missing or non-numeric reading as `0` (Ruby's own `nil.to_i` —
/// a missing/wrong-shaped arg is `0`, never a panic or a refusal, matching
/// `QueryConditionValue::Arg`'s own `unwrap_or(Json::Null)` miss-is-null
/// reading one step further down to a count). Negative floors to `0` —
/// `Vec::truncate` has no negative case, and neither does a real limit.
fn resolve_limit(limit: &Limit, args: &Json) -> usize {
    let raw = match limit {
        Limit::Literal(n) => *n,
        Limit::Arg(name) => args.get(name).and_then(Json::as_i64).unwrap_or(0),
    };
    raw.max(0) as usize
}
