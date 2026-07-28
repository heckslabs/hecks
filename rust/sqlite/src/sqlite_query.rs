
use crate::sqlite_mapping::quote_ident;
use crate::sqlite_repository::SqliteRepository;
use storehouse::runtime::AggregateState;
use std::collections::HashMap;

impl SqliteRepository {
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
