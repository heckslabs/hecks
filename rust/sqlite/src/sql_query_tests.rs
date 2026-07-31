
use crate::sql_query::build_pushdown;
use storehouse::ir::{WhereClause, WhereOp};
use rusqlite::types::Value as SqlValue;
use std::collections::HashMap;

fn clause(field: &str, op: WhereOp, value: &str) -> WhereClause {
    WhereClause { field: field.into(), op, value: value.into() }
}

fn cols() -> Vec<String> {
    vec!["status".to_string(), "priority".to_string()]
}

fn nums() -> Vec<String> {
    vec!["priority".to_string()]
}

#[test]
fn eq_builds_cast_text_bound_param() {
    let attrs = HashMap::new();
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::Eq, "pending")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) = ?1");
    assert_eq!(params, vec![SqlValue::Text("pending".into())]);
}

#[test]
fn in_builds_placeholder_list_bound_params() {
    let attrs = HashMap::new();
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::In, "a, b ,c")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) IN (?1, ?2, ?3)");
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
        build_pushdown(&[clause("status", WhereOp::Eq, ":st")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) = ?1");
    assert_eq!(params, vec![SqlValue::Text("shipped".into())]);
}

#[test]
fn injection_value_is_bound_never_interpolated() {
    let attrs = HashMap::new();
    let evil = "x'; DROP TABLE ticket; --";
    let (sql, params) =
        build_pushdown(&[clause("status", WhereOp::Eq, evil)], &attrs, &cols(), &nums()).unwrap();
    assert!(!sql.contains("DROP"));
    assert_eq!(sql, "COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) = ?1");
    assert_eq!(params, vec![SqlValue::Text(evil.into())]);
}

#[test]
fn unknown_column_is_dropped_not_emitted() {
    let attrs = HashMap::new();
    let out = build_pushdown(
        &[clause("status; DROP TABLE ticket", WhereOp::Eq, "x")],
        &attrs,
        &cols(),
        &nums(),
    );
    assert!(out.is_none());
}

#[test]
fn ne_and_contains_are_always_left_to_oracle() {
    let attrs = HashMap::new();
    for op in [WhereOp::Ne, WhereOp::Contains] {
        assert!(
            build_pushdown(&[clause("status", op, "pending")], &attrs, &cols(), &nums()).is_none(),
            "Ne / Contains never push"
        );
    }
}

#[test]
fn numeric_target_on_non_integer_column_is_left_to_oracle() {
    let attrs = HashMap::new();
    for op in [WhereOp::Gt, WhereOp::Gte, WhereOp::Lt, WhereOp::Lte] {
        assert!(
            build_pushdown(&[clause("status", op, "5")], &attrs, &cols(), &nums()).is_none(),
            "numeric target on a non-integer column defers to oracle"
        );
    }
}

#[test]
fn numeric_target_on_integer_column_pushes_as_cast_integer() {
    let attrs = HashMap::new();
    let (sql, params) =
        build_pushdown(&[clause("priority", WhereOp::Gt, "5")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "CAST(\"priority\" AS INTEGER) > ?1");
    assert_eq!(params, vec![SqlValue::Integer(5)]);

    let (sql, _) =
        build_pushdown(&[clause("priority", WhereOp::Gte, "9")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "CAST(\"priority\" AS INTEGER) >= ?1");

    let (sql, params) =
        build_pushdown(&[clause("priority", WhereOp::Lt, "5")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "(\"priority\" IS NULL OR CAST(\"priority\" AS INTEGER) < ?1)");
    assert_eq!(params, vec![SqlValue::Integer(5)]);

    let (sql, _) =
        build_pushdown(&[clause("priority", WhereOp::Lte, "2")], &attrs, &cols(), &nums()).unwrap();
    assert_eq!(sql, "(\"priority\" IS NULL OR CAST(\"priority\" AS INTEGER) <= ?1)");
}

#[test]
fn nonnumeric_target_ordered_ops_push_as_cast_text() {
    let attrs = HashMap::new();
    let ops = [
        (WhereOp::Gt, ">"),
        (WhereOp::Gte, ">="),
        (WhereOp::Lt, "<"),
        (WhereOp::Lte, "<="),
    ];
    for (op, sym) in ops {
        let (sql, params) =
            build_pushdown(&[clause("status", op, "pending")], &attrs, &cols(), &nums()).unwrap();
        assert_eq!(sql, format!("COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) {} ?1", sym));
        assert_eq!(params, vec![SqlValue::Text("pending".into())]);
    }
}

#[test]
fn empty_ordered_target_is_left_to_oracle() {
    let attrs = HashMap::new();
    assert!(build_pushdown(&[clause("status", WhereOp::Gt, "")], &attrs, &cols(), &nums()).is_none());
}

#[test]
fn empty_eq_target_is_left_to_oracle() {
    let attrs = HashMap::new();
    assert!(build_pushdown(&[clause("status", WhereOp::Eq, "")], &attrs, &cols(), &nums()).is_none());
}

#[test]
fn mixed_clauses_push_only_the_pushable_subset() {
    let attrs = HashMap::new();
    let (sql, params) = build_pushdown(
        &[
            clause("status", WhereOp::Eq, "pending"),
            clause("priority", WhereOp::Ne, "3"), 
        ],
        &attrs,
        &cols(),
        &nums(),
    )
    .unwrap();
    assert_eq!(sql, "COALESCE(CASE WHEN json_valid(\"status\") THEN json_extract(\"status\", '$.value') END, CAST(\"status\" AS TEXT)) = ?1");
    assert_eq!(params.len(), 1);
}
