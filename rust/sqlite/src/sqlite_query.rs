//! sqlite_query — the where()-pushdown surface on the SQL backend
//!
//! Split from sqlite_repository (the CRUD substrate) by concern : this is the
//! READ side that the where() overhaul adds — the injection-safe pushdown query
//! (Phase 1) and the expression indexes that make it affordable (Phase 3). It
//! reaches SqliteRepository's `pub(super)` connection / typed columns / cache.
//!
//! Host-only : depends on rusqlite. The wasm SqliteRepository stub carries its
//! own (unreachable) query / ensure_indexes.

use crate::sqlite_mapping::quote_ident;
use crate::sqlite_repository::SqliteRepository;
use storehouse::runtime::AggregateState;
use std::collections::HashMap;

impl SqliteRepository {
    /// Injection-safe pushdown query (where() Phase 1). Builds a parameterized
    /// prefilter for the PUSHABLE clauses (sql_query) and runs it against the
    /// live connection, returning OWNED candidate states. The runtime's
    /// `where_matches` oracle re-applies EVERY clause on top, so this is a SAFE
    /// PREFILTER — it never drops a row the oracle would keep. Falls back to the
    /// full in-memory store when nothing is pushable or the query errors (never
    /// a silent empty result).
    pub fn query(
        &self,
        wheres: &[storehouse::ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Vec<AggregateState> {
        match crate::sql_query::build_pushdown(wheres, attrs, &self.columns, &self.numeric_columns) {
            Some((where_sql, params)) => crate::sql_query::run_filtered(
                &self.conn, &self.table, &self.columns, &where_sql, &params,
            )
            .unwrap_or_else(|| self.store.values().cloned().collect()),
            None => self.store.values().cloned().collect(),
        }
    }

    /// Create an EXPRESSION index on `CAST(col AS TEXT)` for each column the
    /// aggregate's declared where()/order_by name (where() Phase 3). The Phase-1
    /// pushdown filters as `WHERE CAST(col AS TEXT) = ?` ; a plain column index
    /// would not serve that expression, so the index is on the SAME expression
    /// — keeping the pushdown both parity-faithful AND index-backed. Unknown
    /// columns are skipped (only declared columns are ever emitted, so the DDL
    /// holds no caller-supplied string). `IF NOT EXISTS` makes it idempotent
    /// across boots ; a failed CREATE INDEX is swallowed (the query still works,
    /// just unindexed) rather than taking down the bus.
    pub fn ensure_indexes(&self, columns: &[String]) {
        for col in columns {
            if !self.columns.iter().any(|c| c == col) {
                continue;
            }
            let ddl = format!(
                "CREATE INDEX IF NOT EXISTS {idx} ON {t} (CAST({c} AS TEXT))",
                idx = quote_ident(&format!("idx_{}_{}_text", self.table, col)),
                t = quote_ident(&self.table),
                c = quote_ident(col),
            );
            let _ = self.conn.execute(&ddl, []);
            // Numeric range pushdown (Gt/Gte/Lt/Lte on an INTEGER column) filters
            // as `CAST(col AS INTEGER) OP ?` ; an INTEGER-cast expression index
            // serves that — the text index does not. Created only for INTEGER
            // columns, the only ones the numeric pushdown targets.
            if self.numeric_columns.iter().any(|c| c == col) {
                let int_ddl = format!(
                    "CREATE INDEX IF NOT EXISTS {idx} ON {t} (CAST({c} AS INTEGER))",
                    idx = quote_ident(&format!("idx_{}_{}_int", self.table, col)),
                    t = quote_ident(&self.table),
                    c = quote_ident(col),
                );
                let _ = self.conn.execute(&int_ddl, []);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // where() Phase 3 : ensure_indexes creates an EXPRESSION index that the
    // Phase-1 pushdown's `WHERE CAST(col AS TEXT) = ?` actually USES — proven
    // via the query planner, not just index existence.
    #[test]
    fn ensure_indexes_makes_pushdown_use_an_index() {
        let path = std::env::temp_dir()
            .join(format!("sqlite_idx_{}.db", std::process::id()))
            .to_string_lossy()
            .into_owned();
        let _ = std::fs::remove_file(&path);
        let cols = vec![("status".to_string(), "VARCHAR(255)".to_string())];
        let repo = SqliteRepository::new("Ticket", &path, None, cols).unwrap();
        repo.ensure_indexes(&["status".to_string()]);
        let plan: String = repo
            .conn
            .query_row(
                "EXPLAIN QUERY PLAN SELECT id, status FROM ticket WHERE CAST(status AS TEXT) = ?1",
                ["x"],
                |r| r.get::<_, String>(3),
            )
            .unwrap_or_default();
        assert!(plan.to_uppercase().contains("INDEX"), "planner did not use index : {plan}");
    }
}
