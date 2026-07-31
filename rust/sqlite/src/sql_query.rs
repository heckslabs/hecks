
use crate::sqlite_mapping::quote_ident;
use storehouse::runtime::AggregateState;
use storehouse::ir::{WhereClause, WhereOp};
use rusqlite::types::Value as SqlValue;
use std::collections::HashMap;

fn resolve(value: &str, attrs: &HashMap<String, String>) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// What the builder knows about a table's columns.
///
/// Three categories, not two. `columns` says a name is real ; `numeric_columns`
/// says the column itself holds a number ; `numeric_paths` says the column holds
/// JSON and the number is at a declared path inside it. That third one is what
/// the two Vecs could not express, and its absence is why a comparison on a
/// value-object column matched nothing.
pub struct ColumnFacts<'a> {
    pub columns: &'a [String],
    pub numeric_columns: &'a [String],
    pub numeric_paths: &'a HashMap<String, String>,
}

/// THE NUMBER A VALUE-OBJECT COLUMN HOLDS, at the path the aggregate declares.
///
/// Guarded by `json_valid` because `json_extract` does not return NULL on text
/// that is not JSON — it ABORTS THE STATEMENT:
///
/// ```text
/// sqlite> select json_extract('abc', '$.cents');
/// Error: stepping, malformed JSON
/// ```
///
/// Ruby digs unguarded and gets away with it only because every value-object
/// cell it has met was written by its own encoder.
pub(crate) fn numeric_of(column: &str, path: &str) -> String {
    let quoted = quote_ident(column);
    format!("CASE WHEN json_valid({quoted}) THEN json_extract({quoted}, '$.{path}') END")
}

/// THE SCALAR A COLUMN HOLDS, whatever shape it was stored in.
///
/// A value-object column stores its JSON object, so comparing the column's text
/// against a scalar matched NOTHING — and matched nothing silently, because
/// `SqliteRepository::query` falls back to the full store only when pushdown
/// returns None, never when it returns an empty set. So a `where` on such a
/// column answered less than the in-memory oracle and nothing said so.
///
/// Ruby's `query_expression` digs `$.value` for exactly this reason. This is the
/// same reading in SQL, guarded by `json_valid` because `json_extract` raises on
/// text that is not JSON — which every ordinary column holds.
pub(crate) fn scalar_of(column: &str) -> String {
    let quoted = quote_ident(column);
    format!(
        "COALESCE(CASE WHEN json_valid({quoted}) THEN json_extract({quoted}, '$.value') END, CAST({quoted} AS TEXT))"
    )
}

/// A number the way SQLite will store it, so the bind matches the expression.
///
/// `json_extract` yields a real INTEGER/REAL and carries no column affinity, so
/// `json_extract(...) = '2500'` is FALSE while `= 2500` is true. Binding text
/// against a numeric expression is the whole of the Eq/In bug.
fn numeric_bind(target: &str) -> Option<SqlValue> {
    if let Ok(whole) = target.parse::<i64>() {
        return Some(SqlValue::Integer(whole));
    }
    target.parse::<f64>().ok().map(SqlValue::Real)
}

pub fn build_pushdown(
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
    facts: &ColumnFacts<'_>,
) -> Option<(String, Vec<SqlValue>)> {
    let mut clauses: Vec<String> = Vec::new();
    let mut params: Vec<SqlValue> = Vec::new();

    for w in wheres {
        if !facts.columns.iter().any(|c| c == &w.field) {
            continue;
        }
        // WHICH READING THIS COLUMN GETS. A value-object column holds JSON with
        // the number at a declared path ; everything else compares as its own
        // text. Mixing the two is how you under-return: `scalar_of` on
        // `{"cents":1200}` digs a `$.value` that is not there and falls back to
        // the whole JSON string, while the dispatcher reads 1200.
        let path = facts.numeric_paths.get(&w.field);

        match w.op {
            WhereOp::Eq => {
                let target = resolve(&w.value, attrs);
                if target.is_empty() {
                    continue;
                }
                match path {
                    Some(path) => {
                        // No numeric target for a numeric column: emit nothing
                        // rather than compare against the wrong reading.
                        let Some(bind) = numeric_bind(&target) else { continue };
                        params.push(bind);
                        clauses.push(format!("{} = ?{}", numeric_of(&w.field, path), params.len()));
                    }
                    None => {
                        params.push(SqlValue::Text(target));
                        clauses.push(format!("{} = ?{}", scalar_of(&w.field), params.len()));
                    }
                }
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
                // All or nothing: one unparseable member on a numeric column
                // would silently drop that member from the set.
                let binds: Option<Vec<SqlValue>> = match path {
                    Some(_) => members.iter().map(|m| numeric_bind(m)).collect(),
                    None => Some(members.iter().map(|m| SqlValue::Text(m.to_string())).collect()),
                };
                let Some(binds) = binds else { continue };

                let mut placeholders: Vec<String> = Vec::new();
                for bind in binds {
                    params.push(bind);
                    placeholders.push(format!("?{}", params.len()));
                }
                let column = match path {
                    Some(path) => numeric_of(&w.field, path),
                    None => scalar_of(&w.field),
                };
                clauses.push(format!("{} IN ({})", column, placeholders.join(", ")));
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

                if let Some(path) = path {
                    let Some(bind) = numeric_bind(&target) else { continue };
                    params.push(bind);
                    let expression = numeric_of(&w.field, path);
                    // GUARDED ON ALL FOUR, not just Lt/Lte. A cell whose JSON
                    // does not carry the declared path yields SQL NULL while the
                    // dispatcher may still find a number in it, and dropping a
                    // row the dispatcher would keep is an UNDER-RETURN — the one
                    // thing the candidates contract forbids. Guarding uniformly
                    // makes the superset property hold by construction: SQL drops
                    // a row only when it positively knows the number.
                    clauses.push(format!(
                        "({expression} IS NULL OR {expression} {sql_op} ?{})",
                        params.len()
                    ));
                } else if let Ok(n) = target.parse::<i64>() {
                    if !facts.numeric_columns.iter().any(|c| c == &w.field) {
                        continue;
                    }
                    params.push(SqlValue::Integer(n));
                    let cmp = format!("CAST({} AS INTEGER) {} ?{}", quote_ident(&w.field), sql_op, params.len());
                    match w.op {
                        WhereOp::Lt | WhereOp::Lte => {
                            clauses.push(format!("({} IS NULL OR {})", quote_ident(&w.field), cmp));
                        }
                        _ => clauses.push(cmp),
                    }
                } else {
                    params.push(SqlValue::Text(target));
                    clauses.push(format!("{} {} ?{}", scalar_of(&w.field), sql_op, params.len()));
                }
            }
            _ => {}
        }
    }

    if clauses.is_empty() {
        None
    } else {
        Some((clauses.join(" AND "), params))
    }
}

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
