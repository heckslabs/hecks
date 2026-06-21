//! sql_query_tests — unit tests for the injection-safe WHERE pushdown builder
//!
//! Covers `build_pushdown` in isolation : the SQL text it emits, the bound
//! params, and the injection / unknown-column / not-pushed guards. The
//! end-to-end SQL ↔ where_matches parity (over a real SqliteRepository) lives
//! in `query_parity_tests`.

use super::sql_query::build_pushdown;
use crate::ir::{WhereClause, WhereOp};
use rusqlite::types::Value as SqlValue;
use std::collections::HashMap;

fn clause(field: &str, op: WhereOp, value: &str) -> WhereClause {
    WhereClause { field: field.into(), op, value: value.into() }
}

fn cols() -> Vec<String> {
    vec!["status".to_string(), "priority".to_string()]
}

#[test]
fn eq_builds_cast_text_bound_param() {
    let attrs = HashMap::new();
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::Eq, "pending")], &attrs, &cols()).unwrap();
    assert_eq!(sql, "CAST(status AS TEXT) = ?1");
    assert_eq!(params, vec![SqlValue::Text("pending".into())]);
}

#[test]
fn in_builds_placeholder_list_bound_params() {
    let attrs = HashMap::new();
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::In, "a, b ,c")], &attrs, &cols()).unwrap();
    assert_eq!(sql, "CAST(status AS TEXT) IN (?1, ?2, ?3)");
    assert_eq!(
        params,
        vec![
            SqlValue::Text("a".into()),
            SqlValue::Text("b".into()),
            SqlValue::Text("c".into()),
        ]
    );
}

#[test]
fn kwarg_ref_resolves_from_attrs() {
    let mut attrs = HashMap::new();
    attrs.insert("st".to_string(), "shipped".to_string());
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::Eq, ":st")], &attrs, &cols()).unwrap();
    assert_eq!(sql, "CAST(status AS TEXT) = ?1");
    assert_eq!(params, vec![SqlValue::Text("shipped".into())]);
}

#[test]
fn injection_value_is_bound_never_interpolated() {
    let attrs = HashMap::new();
    let evil = "x'; DROP TABLE ticket; --";
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::Eq, evil)], &attrs, &cols()).unwrap();
    // The malicious string never appears in the SQL text — only a ?N.
    assert!(!sql.contains("DROP"));
    assert_eq!(sql, "CAST(status AS TEXT) = ?1");
    assert_eq!(params, vec![SqlValue::Text(evil.into())]);
}

#[test]
fn unknown_column_is_dropped_not_emitted() {
    let attrs = HashMap::new();
    // A field name not in the trusted column list never reaches SQL.
    let out = build_pushdown(
        &[clause("status; DROP TABLE ticket", WhereOp::Eq, "x")],
        &attrs,
        &cols(),
    );
    assert!(out.is_none());
}

#[test]
fn ordered_and_ne_ops_are_left_to_oracle() {
    let attrs = HashMap::new();
    for op in [WhereOp::Ne, WhereOp::Gt, WhereOp::Gte, WhereOp::Lt, WhereOp::Lte, WhereOp::Contains] {
        assert!(
            build_pushdown(&[clause("priority", op, "5")], &attrs, &cols()).is_none(),
            "op should not push this phase"
        );
    }
}

#[test]
fn empty_eq_target_is_left_to_oracle() {
    let attrs = HashMap::new();
    assert!(build_pushdown(&[clause("status", WhereOp::Eq, "")], &attrs, &cols()).is_none());
}

#[test]
fn mixed_clauses_push_only_the_pushable_subset() {
    let attrs = HashMap::new();
    let (sql, params) = build_pushdown(
        &[
            clause("status", WhereOp::Eq, "pending"),
            clause("priority", WhereOp::Gt, "3"), // not pushed
        ],
        &attrs,
        &cols(),
    )
    .unwrap();
    assert_eq!(sql, "CAST(status AS TEXT) = ?1");
    assert_eq!(params.len(), 1);
}
