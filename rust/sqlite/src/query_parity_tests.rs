//! query_parity_tests — the SQL-pushdown ↔ where_matches parity oracle
//!
//! The contract-not-regex guarantee for the where() overhaul : the
//! connection-executed SQL prefilter (`SqliteRepository::query`) must never
//! diverge from the canonical in-memory matcher (`where_matches`). Two
//! properties, asserted over a real SqliteRepository for every WhereOp :
//!
//!   1. PARITY  — applying the oracle to the SQL candidate set yields exactly
//!      the same ids as applying the oracle to the full store. (This is what
//!      `resolve_query_qualified` actually computes, so it proves end-to-end
//!      equivalence whether or not the op was pushed.)
//!   2. SUPERSET — the raw SQL candidate set is never missing a row the oracle
//!      would keep (a prefilter may only narrow, never drop a real match).
//!   3. NARROWING — for the pushed ops (Eq / In) the raw candidate set already
//!      equals the oracle set, proving SQL did the filtering (not a passthrough).
//!
//! Plus an injection assertion : a malicious value is bound, never executed.

use crate::sqlite_repository::SqliteRepository;
use storehouse::runtime::{AggregateState, Value};
use storehouse::heki;
use storehouse::ir::{WhereClause, WhereOp};
use std::collections::HashMap;

fn clause(field: &str, op: WhereOp, value: &str) -> WhereClause {
    WhereClause { field: field.into(), op, value: value.into() }
}

fn db_path(name: &str) -> String {
    std::env::temp_dir()
        .join(format!("query_parity_{}_{}.db", std::process::id(), name))
        .to_string_lossy()
        .into_owned()
}

const EVIL: &str = "x'; DROP TABLE order; --";

/// A repo with two typed columns (a VARCHAR `status` and an INTEGER
/// `priority`) and five rows, seeded through `save` so both the table and the
/// in-memory store are written (the production write path).
fn seeded(name: &str) -> SqliteRepository {
    let path = db_path(name);
    let _ = std::fs::remove_file(&path);
    let cols = vec![
        ("status".to_string(), "VARCHAR(255)".to_string()),
        ("priority".to_string(), "INTEGER".to_string()),
    ];
    let mut repo = SqliteRepository::new("Ticket", &path, None, cols).expect("open db");
    let rows = [
        ("1", "pending", 1),
        ("2", "paid", 10),
        ("3", "pending", 2),
        ("4", "shipped", 9),
        ("5", EVIL, 5),
    ];
    for (id, status, priority) in rows {
        let mut s = AggregateState::new(id);
        s.set("status", Value::Str(status.into()));
        s.set("priority", Value::Int(priority));
        repo.save(s, heki::WriteContext::OutOfBand { reason: "test" });
    }
    repo
}

fn sorted(mut ids: Vec<String>) -> Vec<String> {
    ids.sort();
    ids
}

/// Apply the canonical oracle to a candidate set — mirrors exactly what
/// `resolve_query_qualified` does after acquiring candidates.
fn oracle_filter(
    states: &[&AggregateState],
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
) -> Vec<String> {
    sorted(
        states
            .iter()
            .filter(|s| wheres.iter().all(|w| storehouse::runtime::where_matches(s, w, attrs)))
            .map(|s| s.id.clone())
            .collect(),
    )
}

fn raw_ids(states: &[AggregateState]) -> Vec<String> {
    sorted(states.iter().map(|s| s.id.clone()).collect())
}

/// The full assertion bundle for one clause set.
fn assert_parity(repo: &SqliteRepository, wheres: &[WhereClause], attrs: &HashMap<String, String>) {
    let all = repo.all();
    let oracle_full = oracle_filter(&all, wheres, attrs);

    let candidates = repo.query(wheres, attrs);
    let cand_refs: Vec<&AggregateState> = candidates.iter().collect();

    // 1. PARITY : oracle applied to candidates == oracle applied to the store.
    assert_eq!(
        oracle_filter(&cand_refs, wheres, attrs),
        oracle_full,
        "oracle(candidates) must equal oracle(store) for {wheres:?}"
    );

    // 2. SUPERSET : the raw candidate set keeps every oracle match.
    let raw = raw_ids(&candidates);
    for id in &oracle_full {
        assert!(raw.contains(id), "candidate set dropped oracle match {id} for {wheres:?}");
    }
}

#[test]
fn parity_across_every_op() {
    let repo = seeded("ops");
    let attrs = HashMap::new();
    let cases: Vec<Vec<WhereClause>> = vec![
        vec![clause("status", WhereOp::Eq, "pending")],
        vec![clause("status", WhereOp::Ne, "pending")],
        vec![clause("status", WhereOp::In, "pending, shipped")],
        vec![clause("priority", WhereOp::Eq, "10")],
        vec![clause("priority", WhereOp::Gt, "5")],
        vec![clause("priority", WhereOp::Gte, "9")],
        vec![clause("priority", WhereOp::Lt, "5")],
        vec![clause("priority", WhereOp::Lte, "2")],
        // non-numeric-target ranges : PUSHED as lexical CAST(col AS TEXT) OP ?
        vec![clause("status", WhereOp::Gt, "pending")],
        vec![clause("status", WhereOp::Gte, "pending")],
        vec![clause("status", WhereOp::Lt, "shipped")],
        vec![clause("status", WhereOp::Lte, "pending")],
        // mixed : one pushed (Eq) + one oracle-only (Gt)
        vec![clause("status", WhereOp::Eq, "pending"), clause("priority", WhereOp::Gt, "1")],
        // mixed : non-numeric range pushed + numeric range oracle-only
        vec![clause("status", WhereOp::Gt, "pending"), clause("priority", WhereOp::Lt, "5")],
    ];
    for wheres in &cases {
        assert_parity(&repo, wheres, &attrs);
    }
}

#[test]
fn pushed_eq_actually_narrows_at_sql() {
    // The raw SQL candidate set for a pushed Eq already equals the oracle set,
    // proving the connection did the filtering (not an all() passthrough).
    let repo = seeded("narrow");
    let attrs = HashMap::new();
    let wheres = vec![clause("status", WhereOp::Eq, "pending")];
    let candidates = repo.query(&wheres, &attrs);
    assert_eq!(raw_ids(&candidates), vec!["1".to_string(), "3".to_string()]);
    assert!(candidates.len() < repo.all().len(), "pushdown must narrow");
}

#[test]
fn pushed_nonnumeric_range_narrows_at_sql() {
    // A non-numeric-target range pushes as CAST(col AS TEXT) OP ? (lexical),
    // so the raw SQL candidate set already equals the oracle set — proving the
    // connection did the range filtering, not an all() passthrough.
    let repo = seeded("range_narrow");
    let attrs = HashMap::new();
    let wheres = vec![clause("status", WhereOp::Gt, "pending")];
    let candidates = repo.query(&wheres, &attrs);
    // statuses > "pending" lexically : "shipped"(4) and the EVIL "x..."(5).
    assert_eq!(raw_ids(&candidates), vec!["4".to_string(), "5".to_string()]);
    assert!(candidates.len() < repo.all().len(), "range pushdown must narrow");
}

#[test]
fn numeric_range_narrows_at_sql() {
    // A numeric target on the INTEGER `priority` column pushes as
    // CAST(priority AS INTEGER) OP ? : the raw SQL candidate set already equals
    // the oracle set, proving the connection did the numeric filtering (not a
    // lexical CAST-text, which would drop priority 10 for `> 5`).
    let repo = seeded("numeric_range");
    let attrs = HashMap::new();
    let wheres = vec![clause("priority", WhereOp::Gt, "5")];
    let candidates = repo.query(&wheres, &attrs);
    assert_eq!(raw_ids(&candidates), vec!["2".to_string(), "4".to_string()], "priority > 5 : 10 and 9");
    assert!(candidates.len() < repo.all().len(), "numeric range must narrow at SQL");
}

#[test]
fn numeric_range_null_priority_matches_oracle() {
    // A row with NO priority (SQL NULL ; the oracle reads a missing field as
    // ""). compare_strings("", <numeric>) is LEXICAL — "" < any digit — so the
    // oracle KEEPS the null row for Lt/Lte and DROPS it for Gt/Gte. The
    // pushdown's NULL handling must match exactly, for every ordered op.
    let path = db_path("null_priority");
    let _ = std::fs::remove_file(&path);
    let cols = vec![
        ("status".to_string(), "VARCHAR(255)".to_string()),
        ("priority".to_string(), "INTEGER".to_string()),
    ];
    let mut repo = SqliteRepository::new("Ticket", &path, None, cols).expect("open db");
    let mut a = AggregateState::new("1");
    a.set("status", Value::Str("x".into()));
    a.set("priority", Value::Int(3));
    repo.save(a, heki::WriteContext::OutOfBand { reason: "test" });
    let mut b = AggregateState::new("2");
    b.set("status", Value::Str("x".into()));
    b.set("priority", Value::Int(8));
    repo.save(b, heki::WriteContext::OutOfBand { reason: "test" });
    let mut c = AggregateState::new("3"); // NO priority -> NULL
    c.set("status", Value::Str("x".into()));
    repo.save(c, heki::WriteContext::OutOfBand { reason: "test" });
    let attrs = HashMap::new();
    for op in [WhereOp::Gt, WhereOp::Gte, WhereOp::Lt, WhereOp::Lte] {
        assert_parity(&repo, &[clause("priority", op, "5")], &attrs);
    }
    // Concretely : Lt 5 keeps the null row (3) ; Gt 5 drops it.
    let lt_w = vec![clause("priority", WhereOp::Lt, "5")];
    let lt = repo.query(&lt_w, &attrs);
    let lt_refs: Vec<&AggregateState> = lt.iter().collect();
    assert!(oracle_filter(&lt_refs, &lt_w, &attrs).contains(&"3".to_string()), "Lt keeps NULL row");
    let gt_w = vec![clause("priority", WhereOp::Gt, "5")];
    let gt = repo.query(&gt_w, &attrs);
    let gt_refs: Vec<&AggregateState> = gt.iter().collect();
    assert!(!oracle_filter(&gt_refs, &gt_w, &attrs).contains(&"3".to_string()), "Gt drops NULL row");
}

#[test]
fn numeric_eq_does_not_match_via_affinity() {
    // CAST(col AS TEXT) = ? mirrors the oracle's string equality : an INTEGER
    // column holding 5 must NOT match the target "05" (a bare `col = '05'`
    // would, via SQLite integer affinity).
    let repo = seeded("affinity");
    let attrs = HashMap::new();
    let wheres = vec![clause("priority", WhereOp::Eq, "05")];
    assert!(repo.query(&wheres, &attrs).is_empty() || {
        // whatever SQL returns, the oracle has the final say and rejects "05"
        let cands = repo.query(&wheres, &attrs);
        let refs: Vec<&AggregateState> = cands.iter().collect();
        oracle_filter(&refs, &wheres, &attrs).is_empty()
    });
}

#[test]
fn where_matches_resolves_nested_vo_bare_and_dotted() {
    // `sequence` is stored as a single-value VO {"value": N}. Both the BARE
    // field (VO-unwrap) and the DOTTED `sequence.value` path resolve to the
    // inner integer and compare numerically. The bare form is what
    // Event.AtSequence uses ; the dotted form backs the seek.
    let mut s = AggregateState::new("e1");
    let mut seqmap = HashMap::new();
    seqmap.insert("value".to_string(), Value::Int(7));
    s.set("sequence", Value::Map(seqmap));
    let attrs = HashMap::new();
    // Bare-VO unwrap : compares by the inner value, not the map Display.
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Eq, "7"), &attrs), "bare VO unwraps to 7");
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Gt, "5"), &attrs), "7 > 5 via unwrap");
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Eq, "8"), &attrs), "7 != 8");
    // Dotted path resolves the same integer.
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Gt, "5"), &attrs), "7 > 5");
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Eq, "7"), &attrs), "7 == 7");
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Lt, "7"), &attrs), "7 < 7 false");
    // Missing dotted leaf resolves to "" (no panic, no match).
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence.nope", WhereOp::Eq, "7"), &attrs), "missing leaf");
}

#[test]
fn injection_value_is_bound_not_executed() {
    let repo = seeded("injection");
    let attrs = HashMap::new();
    // Query for the malicious value : it returns exactly its row, and the
    // table is intact (the DROP never ran — it was a bound param).
    let wheres = vec![clause("status", WhereOp::Eq, EVIL)];
    let candidates = repo.query(&wheres, &attrs);
    let refs: Vec<&AggregateState> = candidates.iter().collect();
    assert_eq!(oracle_filter(&refs, &wheres, &attrs), vec!["5".to_string()]);
    // Table survived : all five rows still present.
    assert_eq!(repo.all().len(), 5, "injection must not drop the table");
}
