
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

pub fn build_pushdown(
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
    valid_cols: &[String],
    numeric_cols: &[String],
) -> Option<(String, Vec<SqlValue>)> {
    let mut clauses: Vec<String> = Vec::new();
    let mut params: Vec<SqlValue> = Vec::new();

    for w in wheres {
        if !valid_cols.iter().any(|c| c == &w.field) {
            continue;
        }
        match w.op {
            WhereOp::Eq => {
                let target = resolve(&w.value, attrs);
                if target.is_empty() {
                    continue;
                }
                params.push(SqlValue::Text(target));
                clauses.push(format!("{} = ?{}", scalar_of(&w.field), params.len()));
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
                    "{} IN ({})",
                    scalar_of(&w.field),
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
                    if !numeric_cols.iter().any(|c| c == &w.field) {
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
