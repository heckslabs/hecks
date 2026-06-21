//! sql_query — injection-safe WHERE pushdown for the SQLite backend
//!
//! The query()-seam half of the where() overhaul (Phase 1). `where_matches`
//! (runtime/mod.rs) stays the canonical op semantics AND the final authority :
//! this builder produces a parameterized SQL prefilter for the subset of
//! clauses SQL can evaluate IDENTICALLY to the oracle, and the runtime
//! re-applies EVERY clause with `where_matches` on top. So a pushdown can only
//! narrow the candidate set for ops it is certain about — never change the
//! result — and parity holds by construction.
//!
//! Injection-safe BY CONSTRUCTION : column names are validated against the
//! aggregate's TRUSTED column list (an unknown field is dropped, never emitted
//! as a raw string), and EVERY value is a BOUND rusqlite param — nothing from
//! the caller is ever interpolated into the SQL text.
//!
//! Pushed ops : `Eq` (non-empty resolved target), `In` (non-empty members), and
//! the ordered ops `Gt / Gte / Lt / Lte` WHEN the resolved target is NON-NUMERIC.
//! Eq / In are pure string-equality, which `CAST(col AS TEXT) = ?` mirrors EXACTLY
//! against the oracle's `field.to_string() == target` — sidestepping SQLite's
//! type-affinity coercions (a bare `col = '5'` would match INTEGER 5 to TEXT
//! "05"; the CAST does not).
//!
//! Ordered ops are parity-safe ONLY for a non-numeric target : the oracle's
//! `compare_strings` takes its numeric branch IFF BOTH sides parse as i64, so a
//! non-numeric target forces a LEXICAL comparison for every row — exactly what
//! `CAST(col AS TEXT) OP ?` does, reusing the Phase-3 text index. This covers the
//! canonical range query (ISO timestamps / dates / name prefixes : `created_at >
//! "2026-01-01"`). A NUMERIC target could hit the oracle's numeric branch ("10" >
//! "5"), which lexical SQL gets wrong and `CAST(col AS INTEGER)` can't replicate
//! faithfully (overflow clamps ; a NULL cell flips Lt) — so numeric-target ranges
//! are left to the oracle until a typed numeric-column pushdown (retain the
//! column's SQL type + a `(col IS NULL OR CAST(col AS INTEGER) OP ?)` superset +
//! a numeric index) lands. `Ne / Contains / NoneInState` carry negation, list, or
//! cross-aggregate semantics SQL can't replicate, so they are left to the oracle
//! (a no-pushdown clause simply doesn't narrow).
//!
//! Tests : `sql_query_tests` (builder/executor units) and
//! `query_parity_tests` (the SQL ↔ where_matches oracle over a real repo).
//!
//! Host-only : depends on rusqlite. The wasm build uses the heki/memory
//! backend and never reaches this module (see the SqliteRepository wasm stub).
//!
//! Usage:
//!   if let Some((where_sql, params)) = build_pushdown(&wheres, &attrs, &cols) {
//!       let rows = run_filtered(&conn, &table, &cols, &where_sql, &params);
//!   }

use super::AggregateState;
use crate::ir::{WhereClause, WhereOp};
use rusqlite::types::Value as SqlValue;
use std::collections::HashMap;

/// Resolve a where-clause value : `:foo` reads `attrs["foo"]` (kwarg-ref) ;
/// any other token is a literal returned as-is. A local mirror of the
/// runtime's `resolve_where_value` so the builder is self-contained and
/// resolves identically to the oracle before binding.
fn resolve(value: &str, attrs: &HashMap<String, String>) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// Build a parameterized WHERE fragment (no leading `WHERE`) for the PUSHABLE
/// subset of `wheres`, plus the ordered bound params. Returns `None` when no
/// clause is pushable — the caller then keeps the full in-memory candidate set
/// and lets the oracle filter. Clauses are ANDed, mirroring the oracle's
/// `wheres.iter().all(..)`.
pub fn build_pushdown(
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
    valid_cols: &[String],
) -> Option<(String, Vec<SqlValue>)> {
    let mut clauses: Vec<String> = Vec::new();
    let mut params: Vec<SqlValue> = Vec::new();

    for w in wheres {
        // Field-name validation : only a declared column may reach the SQL
        // text. An unknown field is left to the oracle (no narrowing), never
        // interpolated. This is the injection guard on the column side.
        if !valid_cols.iter().any(|c| c == &w.field) {
            continue;
        }
        match w.op {
            WhereOp::Eq => {
                let target = resolve(&w.value, attrs);
                // Empty/missing target : the oracle treats a missing field as
                // "", but SQL NULL = '' is false — so an empty target could
                // drop a real match. Leave it to the oracle (no narrowing).
                if target.is_empty() {
                    continue;
                }
                params.push(SqlValue::Text(target));
                clauses.push(format!("CAST({} AS TEXT) = ?{}", w.field, params.len()));
            }
            WhereOp::In => {
                let resolved = resolve(&w.value, attrs);
                let members: Vec<&str> = resolved
                    .split(',')
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .collect();
                if members.is_empty() {
                    continue;
                }
                let mut placeholders: Vec<String> = Vec::new();
                for m in members {
                    params.push(SqlValue::Text(m.to_string()));
                    placeholders.push(format!("?{}", params.len()));
                }
                clauses.push(format!(
                    "CAST({} AS TEXT) IN ({})",
                    w.field,
                    placeholders.join(", ")
                ));
            }
            WhereOp::Gt | WhereOp::Gte | WhereOp::Lt | WhereOp::Lte => {
                let target = resolve(&w.value, attrs);
                // Range pushdown is parity-safe ONLY for a NON-NUMERIC target.
                // The oracle's `compare_strings` takes its numeric branch IFF
                // BOTH sides parse as i64 ; a target that is not an i64 forces
                // the oracle to compare LEXICALLY for EVERY row, which is
                // EXACTLY what `CAST(col AS TEXT) OP ?` does (and it reuses the
                // Phase-3 text index). A NUMERIC target could hit the oracle's
                // numeric branch ("10" > "5"), which lexical SQL would get wrong,
                // and `CAST(col AS INTEGER)` can't faithfully replicate
                // i64::parse (overflow clamps, NULL flips Lt) — so a numeric
                // target is left to the oracle (no narrowing) until the typed
                // numeric-column pushdown lands. Empty target is skipped for the
                // same NULL reason as Eq.
                if target.is_empty() || target.parse::<i64>().is_ok() {
                    continue;
                }
                let sql_op = match w.op {
                    WhereOp::Gt => ">",
                    WhereOp::Gte => ">=",
                    WhereOp::Lt => "<",
                    WhereOp::Lte => "<=",
                    _ => unreachable!("outer match guarantees an ordered op"),
                };
                params.push(SqlValue::Text(target));
                clauses.push(format!("CAST({} AS TEXT) {} ?{}", w.field, sql_op, params.len()));
            }
            // Ne / Contains / NoneInState / Resolved carry list, cross-aggregate,
            // or negation semantics SQL can't replicate parity-faithfully — left
            // to the oracle (a no-pushdown clause simply doesn't narrow).
            _ => {}
        }
    }

    if clauses.is_empty() {
        None
    } else {
        Some((clauses.join(" AND "), params))
    }
}

/// Run a prebuilt parameterized prefilter against the live connection and
/// hydrate matching rows into owned `AggregateState`s. `None` on any SQL
/// error so the caller can fall back to the full in-memory set (never a
/// silent empty result). Every param is bound — the SQL text holds only
/// validated column names and `?N` placeholders.
pub fn run_filtered(
    conn: &rusqlite::Connection,
    table: &str,
    columns: &[String],
    where_sql: &str,
    params: &[SqlValue],
) -> Option<Vec<AggregateState>> {
    let select = format!(
        "SELECT id, {} FROM {} WHERE {}",
        columns.join(", "),
        table,
        where_sql
    );
    let mut stmt = conn.prepare(&select).ok()?;
    let cols = columns.to_vec();
    let refs: Vec<&dyn rusqlite::ToSql> =
        params.iter().map(|p| p as &dyn rusqlite::ToSql).collect();
    let mapped = stmt
        .query_map(refs.as_slice(), |row| {
            let id: String = row.get(0)?;
            let mut state = AggregateState::new(&id);
            for (i, name) in cols.iter().enumerate() {
                state.set(name, super::sqlite_mapping::value_from_sql(row, i + 1));
            }
            Ok(state)
        })
        .ok()?;
    Some(mapped.flatten().collect())
}
