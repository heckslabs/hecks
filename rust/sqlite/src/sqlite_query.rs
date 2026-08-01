
use crate::sqlite_mapping::quote_ident;
use crate::sqlite_repository::SqliteRepository;
use storehouse::runtime::AggregateState;
use std::collections::HashMap;

impl SqliteRepository {
    /// What this table's columns are, in the three categories the builder needs.
    pub(crate) fn column_facts(&self) -> crate::sql_query::ColumnFacts<'_> {
        crate::sql_query::ColumnFacts {
            columns: &self.columns,
            numeric_columns: &self.numeric_columns,
            numeric_paths: &self.numeric_paths,
        }
    }

    pub fn query(
        &self,
        wheres: &[storehouse::ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Vec<AggregateState> {
        match crate::sql_query::build_pushdown(wheres, attrs, &self.column_facts()) {
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
            // INDEXED ON THE EXPRESSION THE QUERY ACTUALLY USES. SQLite will only
            // reach for an expression index when the two match character for
            // character, so this has to be `sql_query::scalar_of` and not a
            // hand-written cast that happens to resemble it.
            let ddl = format!(
                "CREATE INDEX IF NOT EXISTS {idx} ON {t} ({expr})",
                idx = quote_ident(&format!("idx_{}_{}_text", self.table, col)),
                t = quote_ident(&self.table),
                expr = crate::sql_query::scalar_of(col),
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
            // The value-object columns compare through `numeric_of`, so they need
            // an index on THAT expression — same character-identity rule.
            if let Some(path) = self.numeric_paths.get(col) {
                let path_ddl = format!(
                    "CREATE INDEX IF NOT EXISTS {idx} ON {t} ({expr})",
                    idx = quote_ident(&format!("idx_{}_{}_path", self.table, col)),
                    t = quote_ident(&self.table),
                    expr = crate::sql_query::numeric_of(col, path),
                );
                let _ = self.conn.execute(&path_ddl, []);
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
        let repo = SqliteRepository::new("Ticket", &path, cols, HashMap::new()).unwrap();
        repo.ensure_indexes(&["status".to_string()]);

        // THE QUERY THE REPOSITORY WOULD REALLY RUN, not one written here to
        // resemble it. This test used to spell its own `WHERE CAST(status AS
        // TEXT) = ?1`, so it went on passing when the pushdown expression
        // changed underneath it and the planner quietly stopped using the index.
        let wheres = vec![storehouse::ir::WhereClause {
            field: "status".into(),
            op: storehouse::ir::WhereOp::Eq,
            value: "x".into(),
        }];
        let (where_sql, _params) =
            crate::sql_query::build_pushdown(&wheres, &HashMap::new(), &repo.column_facts())
                .expect("an eq on a known column pushes down");

        let plan: String = repo
            .conn
            .query_row(
                &format!("EXPLAIN QUERY PLAN SELECT id, status FROM ticket WHERE {where_sql}"),
                ["x"],
                |r| r.get::<_, String>(3),
            )
            .unwrap_or_default();
        assert!(plan.to_uppercase().contains("INDEX"), "planner did not use index : {plan}");
    }
}
