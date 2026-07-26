//! query_match — the canonical WHERE-matching oracle + repository keying :
//! repo_key / repo_lookup_key (the (context, name) store addressing),
//! where_matches (the one in-memory clause matcher every read path — and
//! the sqlite SQL-pushdown parity suite — treats as truth), and its value
//! resolvers (compare_strings, resolve_state_field, resolve_where_value,
//! resolve_limit_value). Pure functions — no runtime state.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/query_match.rs — pure-utility query
//!  matching (no domain), relocated verbatim from mod.rs blanket.]

use super::*;

/// i142 Tier 2 — compose the HashMap key for a repository.
/// Same-name aggregates in different bounded contexts get distinct
/// keys ("Library::Inbox" vs "Workshop::Inbox") so they end up with
/// distinct Repository instances and distinct .heki paths.
/// Legacy aggregates without a context use their bare name.
pub fn repo_key(context: Option<&str>, name: &str) -> String {
    match context {
        Some(ctx) => format!("{}::{}", ctx, name),
        None => name.to_string(),
    }
}

// OMITTED ON THE WAY OVER: `repo_lookup_key`.
//
// The only function in this file hecksagain does not use, and the only one
// that costs anything to keep. It takes a &HashMap<String, LazyRepository>,
// which pulls lazy_repository -> lazy_backend -> repository -> repo_hydrate ->
// event_log -> event_log_index -> event_shard, and onward into most of Hecks's
// 22,903-line runtime.
//
// This file bundles two concerns — the query oracle (where_matches, which the
// sqlite adapter's pushdown is tested against) and repository name lookup. The
// subset here splits them, so the boundary is drawn at the function rather than
// the file. Everything retained is verbatim ; nothing was rewritten.
//
// If hecksagain ever grows the repository layer, restore this from
// hecks/rust/src/runtime/query_match.rs rather than reinventing it.

/// i101 — apply one WhereClause to one record. Resolves kwarg-refs
/// (`":author"`) against the dispatch attrs ; literal values match
/// the record's field as a string. Returns true when the record
/// matches the clause, false otherwise.
// pub : the SQL-pushdown <-> oracle parity test (storehouse-sqlite crate) asserts
// the adapter's prefilter agrees with this in-memory oracle, so it must be reachable
// cross-crate as `storehouse::runtime::where_matches`.
pub fn where_matches(
    state: &AggregateState,
    clause: &crate::ir::WhereClause,
    attrs: &std::collections::HashMap<String, String>,
) -> bool {
    let target = resolve_where_value(&clause.value, attrs);
    let actual = resolve_state_field(state, &clause.field);
    match clause.op {
        crate::ir::WhereOp::Eq  => actual == target,
        crate::ir::WhereOp::Ne  => actual != target,
        crate::ir::WhereOp::Gt  => compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::Gte => !compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lt  => compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lte => !compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::In  => target.split(',').any(|item| item.trim() == actual),
        // Resolved is a cross-aggregate op resolved upstream in
        // resolve_query_qualified (needs &Runtime) ; never reached here.
            // Contains : a record LOCAL list field contains the literal value.
            // Aggregate-local (reads the record own list) — Story.DependentsOf : every
            // story whose dependencies list contains the given dep ref.
            crate::ir::WhereOp::Contains => match state.fields.get(&clause.field) {
                Some(Value::List(items)) => items.iter().any(|v| v.to_string() == target),
                Some(Value::Str(csv)) => csv.split(',').any(|x| x.trim() == target),
                _ => false,
            },
        // NoneInState is a cross-aggregate anti-join resolved upstream in
        // resolve_query_qualified (needs &Runtime) ; never reached here.
        crate::ir::WhereOp::NoneInState => true,
    }
}

/// Numeric ordering when both sides parse as i64 ; lexical otherwise.
/// Keeps the runtime executor honest for both string-typed status
/// fields and numeric-typed counters.
pub(super) fn compare_strings(a: &str, b: &str) -> std::cmp::Ordering {
    if let (Ok(an), Ok(bn)) = (a.parse::<i64>(), b.parse::<i64>()) {
        return an.cmp(&bn);
    }
    a.cmp(b)
}

/// Resolve a clause field to its string value, walking a DOTTED path
/// (`sequence.value`) through nested `Value::Map`s. A bare field reads the
/// top-level value as before (a `Value::Map` Displays as `"{N fields}"`, so a
/// bare `sequence` still never matches a number — which is exactly why an
/// Event-Log sequence predicate must use `sequence.value`). Missing field or a
/// non-map mid-path yields "" (the oracle's `unwrap_or_default` parity).
pub(super) fn resolve_state_field(state: &AggregateState, field: &str) -> String {
    let mut parts = field.split('.');
    let head = match parts.next() {
        Some(h) => h,
        None => return String::new(),
    };
    let mut cur = match state.fields.get(head) {
        Some(v) => v,
        None => return String::new(),
    };
    for key in parts {
        match cur {
            Value::Map(m) => match m.get(key) {
                Some(v) => cur = v,
                None => return String::new(),
            },
            _ => return String::new(),
        }
    }
    // Single-value VO unwrap : a VO with exactly one `value` field IS its
    // value, so a bare-VO field (e.g. `sequence` -> {"value": N}) compares by
    // the inner value, not the map's Display ("{1 fields}"). This mirrors how
    // the in-memory behaviors runtime treats a VO, closing the storehouse-side
    // gap that left Event.AtSequence (bare `sequence` Eq) silently unmatched.
    match cur {
        // A present-but-NULL field reads as "" — the SAME as a missing field, so
        // a SQL-hydrated NULL (Value::Null, Display "null") and an in-memory
        // absent field compare identically (the parity contract ; otherwise a
        // NULL column would sort as the literal "null").
        Value::Null => String::new(),
        Value::Map(m) if m.len() == 1 => {
            m.get("value").map(|v| v.to_string()).unwrap_or_else(|| cur.to_string())
        }
        _ => cur.to_string(),
    }
}

/// Resolve a where-clause value : `:foo` reads `attrs["foo"]` (kwarg-ref) ;
/// any other token is a literal returned as-is.
pub(super) fn resolve_where_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// Resolve a limit value : `:foo` reads `attrs["foo"]` and parses as
/// usize ; numeric token parses directly. Returns None when the source
/// can't be parsed (so the executor leaves the result un-truncated).
pub(super) fn resolve_limit_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> Option<usize> {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).and_then(|s| s.parse::<usize>().ok());
    }
    value.parse::<usize>().ok()
}
