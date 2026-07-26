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
//! the ordered ops `Gt / Gte / Lt / Lte`. Eq / In are pure string-equality, which `CAST(col AS TEXT) = ?` mirrors EXACTLY
//! against the oracle's `field.to_string() == target` — sidestepping SQLite's
//! type-affinity coercions (a bare `col = '5'` would match INTEGER 5 to TEXT
//! "05"; the CAST does not).
//!
//! Ordered ops push in two parity-safe shapes, chosen by target type :
//!   * NON-NUMERIC target -> `CAST(col AS TEXT) OP ?`. The oracle's
//!     `compare_strings` takes its numeric branch IFF BOTH sides parse as i64, so
//!     a non-numeric target forces a LEXICAL comparison for every row — exactly
//!     what the text cast does, reusing the text index. The canonical range query
//!     (ISO timestamps / dates / name prefixes : `created_at > "2026-01-01"`).
//!   * NUMERIC target on an INTEGER column -> `CAST(col AS INTEGER) OP ?`, a BOUND
//!     integer. Every cell of an INTEGER column is an i64, so the oracle compares
//!     numerically and the integer cast matches EXACTLY. NULL is exact too : a
//!     missing/NULL cell reads as "" in the oracle (compare_strings("", N) is
//!     lexical, "" < any digit), so Gt/Gte DROP nulls (`CAST(NULL) OP ?` is NULL,
//!     excluded) and Lt/Lte KEEP them (`col IS NULL OR ...`). A numeric target on a
//!     NON-INTEGER column stays with the oracle (per-row it may be numeric or
//!     lexical). ensure_indexes builds a matching `CAST(col AS INTEGER)` index.
//! `Ne / Contains / NoneInState` carry negation, list, or cross-aggregate semantics
//! SQL can't replicate, so they are left to the oracle (no narrowing).
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

use crate::sqlite_mapping::quote_ident;
use storehouse::runtime::AggregateState;
use storehouse::ir::{WhereClause, WhereOp};
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
    numeric_cols: &[String],
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
                clauses.push(format!("CAST({} AS TEXT) = ?{}", quote_ident(&w.field), params.len()));
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
                    quote_ident(&w.field),
                    placeholders.join(", ")
                ));
            }
            WhereOp::Gt | WhereOp::Gte | WhereOp::Lt | WhereOp::Lte => {
                let target = resolve(&w.value, attrs);
                if target.is_empty() {
                    continue;
                }
                let sql_op = match w.op {
                    WhereOp::Gt => ">",
                    WhereOp::Gte => ">=",
                    WhereOp::Lt => "<",
                    WhereOp::Lte => "<=",
                    _ => unreachable!("outer match guarantees an ordered op"),
                };
                if let Ok(n) = target.parse::<i64>() {
                    // NUMERIC target. Pushable IFF the column is INTEGER-typed :
                    // then every cell is an i64, the oracle's compare_strings
                    // takes its numeric branch, and `CAST(col AS INTEGER) OP ?`
                    // (a BOUND integer) matches it EXACTLY. A numeric target on a
                    // non-INTEGER column is left to the oracle — per row it might
                    // be numeric or lexical, and SQL can't tell.
                    if !numeric_cols.iter().any(|c| c == &w.field) {
                        continue;
                    }
                    params.push(SqlValue::Integer(n));
                    let cmp = format!("CAST({} AS INTEGER) {} ?{}", quote_ident(&w.field), sql_op, params.len());
                    // NULL handling, EXACT vs the oracle : a missing cell reads as
                    // "" there, and compare_strings("", <numeric>) is LEXICAL
                    // ("" < any digit). So Lt/Lte KEEP nulls — the SQL `IS NULL OR`
                    // keeps them too — and Gt/Gte DROP them : CAST(NULL)=NULL,
                    // `NULL OP ?` is NULL -> excluded, matching the oracle.
                    match w.op {
                        WhereOp::Lt | WhereOp::Lte => {
                            clauses.push(format!("({} IS NULL OR {})", quote_ident(&w.field), cmp));
                        }
                        _ => clauses.push(cmp),
                    }
                } else {
                    // NON-NUMERIC target : the oracle is LEXICAL for every row
                    // (its numeric branch needs both sides to parse i64), which
                    // `CAST(col AS TEXT) OP ?` mirrors exactly, reusing the text
                    // index. The canonical date / timestamp / prefix range.
                    params.push(SqlValue::Text(target));
                    clauses.push(format!("CAST({} AS TEXT) {} ?{}", quote_ident(&w.field), sql_op, params.len()));
                }
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
    let quoted_cols: Vec<String> = columns.iter().map(|c| quote_ident(c)).collect();
    let select = format!(
        "SELECT id, {} FROM {} WHERE {}",
        quoted_cols.join(", "),
        quote_ident(table),
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
                state.set(name, crate::sqlite_mapping::value_from_sql(row, i + 1));
            }
            Ok(state)
        })
        .ok()?;
    Some(mapped.flatten().collect())
}
