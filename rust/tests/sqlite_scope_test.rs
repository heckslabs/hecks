//! sqlite_scope_test — i735 : `adapter :sqlite` is scoped to the declaring
//! hecksagon's OWN aggregates (matched by `agg.context == hecksagon.name`),
//! never applied domain-wide across a combined multi-context root.
//!
//! Before the fix, a single `:sqlite` hecksagon rebuilt EVERY aggregate in
//! the conception on the SQL backend, panicking the whole bus when an
//! unrelated aggregate carried SQL-incompatible columns. This pins the
//! scoping : attaching a `:sqlite` hecksagon named "Git" makes ONLY the
//! Git-context repositories SQL-backed ; every other context keeps the
//! heki/memory repository `boot_with_data_dir` built.

use std::collections::HashMap;
use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{repo_key, Runtime, RuntimeError, Value};

fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}

// A :sqlite adapter wired ONLY for the "Git" bluebook ; its hecksagon name
// equals the Git aggregates' context. The db path need not exist — boot is
// lazy, no table is created until first repository access.
const GIT_SQLITE_HEX: &str =
    "Hecks.hecksagon \"Git\" do\n  adapter :sqlite, db: \"/tmp/i735_git_scope.db\"\nend\n";

#[test]
fn sqlite_scopes_to_its_declaring_context_only() {
    let domain = load_combined_domain(&aggregates_dir());
    let rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(GIT_SQLITE_HEX)],
    );

    // The declaring context's repository IS SQL-backed.
    let git_repo = rt
        .repositories
        .get(&repo_key(Some("Git"), "Git"))
        .expect("Git::Git repository present in the combined domain");
    assert!(
        git_repo.is_sql(),
        "Git context must be SQL-backed by its own :sqlite hecksagon",
    );

    // A DIFFERENT context is untouched — it keeps heki/memory, NOT SQL.
    // This is the i735 regression guard : the over-apply made this SQL too.
    let policy_repo = rt
        .repositories
        .get(&repo_key(Some("Governance"), "Policy"))
        .expect("Governance::Policy repository present in the combined domain");
    assert!(
        !policy_repo.is_sql(),
        "Governance must NOT be SQL-backed — :sqlite was scoped to Git (i735)",
    );
}

// ---- i735 defect 2 : a SQL-incompatible column refuses the aggregate
//      LOUDLY at boot instead of panicking the live bus ----

const RESERVED_COL_BLUEBOOK: &str = r#"Hecks.bluebook "ReservedCol" do
  aggregate "Thing" do
    attribute :order, String
    command "Make" do
      attribute :order, String
    end
  end
end
"#;

const RESERVED_COL_SQLITE_HEX: &str =
    "Hecks.hecksagon \"ReservedCol\" do\n  adapter :sqlite, db: \"/tmp/i735_reserved_col.db\"\nend\n";

#[test]
fn a_sql_incompatible_column_refuses_the_aggregate_without_panicking() {
    // `order` is a SQL reserved word ; the unquoted column makes CREATE
    // TABLE fail. The whole point of defect 2 : boot must NOT panic.
    let domain = storehouse::parser::parse(RESERVED_COL_BLUEBOOK);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(RESERVED_COL_SQLITE_HEX)],
    );

    let key = repo_key(Some("ReservedCol"), "Thing");
    // The aggregate is REFUSED : no repository survives — never a silent
    // heki swap (Decision 1 : no silent fallback).
    assert!(
        !rt.repositories.contains_key(&key),
        "a refused sqlite aggregate must have NO repository, never a silent heki swap",
    );
    // The loud reason is recorded for a dispatch to surface as
    // RuntimeError::PersistenceRefused.
    assert!(
        rt.refused_persistence.contains_key(&key),
        "the refusal must be recorded with a loud reason (i735 defect 2)",
    );

    // The deliverable : a dispatch against the refused aggregate returns the
    // LOUD PersistenceRefused error — never a panic, never a misleading
    // UnknownAggregate. This also pins that dispatch's repo_hash_key matches
    // the repo_key the refusal was recorded under.
    let err = rt
        .dispatch(
            "ReservedCol::Thing.Make",
            HashMap::from([("order".to_string(), Value::Str("x".into()))]),
        )
        .expect_err("dispatch against a refused-persistence aggregate must error");
    assert!(
        matches!(err, RuntimeError::PersistenceRefused(_)),
        "expected PersistenceRefused, got {err:?}",
    );
}
