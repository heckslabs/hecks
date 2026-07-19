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
    format!("{}/aggregates", storehouse::storehouse_router::conception_root())
}

// A :sqlite adapter wired ONLY for the "Git" bluebook ; its hecksagon name
// equals the Git aggregates' context. The db path need not exist — boot is
// lazy, no table is created until first repository access.
const GIT_SQLITE_HEX: &str =
    "Hecks.hecksagon \"Git\" do\n  adapter :sqlite, db: \"/tmp/i735_git_scope.db\"\nend\n";

#[test]
fn sqlite_scopes_to_its_declaring_context_only() {
    storehouse_sqlite::register();
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
        git_repo.is_adapter(),
        "Git context must be SQL-backed by its own :sqlite hecksagon",
    );

    // EVERY other context is untouched — keeps heki/memory, NOT SQL.
    // This is the i735 regression guard : the over-apply made these SQL
    // too. Sweeping all non-Git repositories (not one pinned aggregate
    // name) keeps the guard honest as the conception evolves — the old
    // Governance::Policy probe rotted away when Policy left Governance
    // in the 2026-06-26 restructure.
    let others: Vec<_> = rt
        .repositories
        .iter()
        .filter(|(key, _)| !key.starts_with("Git::"))
        .collect();
    assert!(!others.is_empty(), "combined domain must contain non-Git contexts");
    for (key, repo) in others {
        assert!(
            !repo.is_adapter(),
            "{key} must NOT be SQL-backed — :sqlite was scoped to Git (i735)",
        );
    }
}

// ---- reserved-word table + column names WORK (quoted identifiers) ----
// i735 defect 2 originally refused a reserved-word column LOUDLY (no panic) ;
// the quoting fix COMPLETES that intent — a reserved word is now a legal quoted
// identifier. An aggregate named `Order` (snake_case table `order`, a SQL
// keyword) with an `order` column and a `status` VO + lifecycle boots
// sqlite-backed and roundtrips. This also pins the DEDUP guard : `status` is
// both a declared attribute AND the lifecycle field, so the pre-fix factory
// emitted `status TEXT, status TEXT` and CREATE TABLE failed on the duplicate.
// Mirrors Pizzas' Order shape exactly.
const RESERVED_WORDS_BLUEBOOK: &str = r#"Hecks.bluebook "Shop" do
      aggregate "Order" do
        attribute :order, String
        attribute :status, OrderStatus, default: "pending" do
          transition "Approve" => "approved"
        end
        value_object "OrderStatus" do
          attribute :value, String
        end
        command "Place" do
          attribute :order, String
        end
        command "Approve" do
          reference_to Order
        end
      end
    end
    "#;

const RESERVED_WORDS_SQLITE_HEX: &str =
    "Hecks.hecksagon \"Shop\" do\n  adapter :sqlite, db: \"/tmp/quoted_reserved_words.db\"\nend\n";

#[test]
fn reserved_word_table_and_columns_roundtrip_when_quoted() {
    storehouse_sqlite::register();
    // Clean any prior db so id sequencing + row-count assertions are deterministic.
    let _ = std::fs::remove_file("/tmp/quoted_reserved_words.db");
    let domain = storehouse::parser::parse(RESERVED_WORDS_BLUEBOOK);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(RESERVED_WORDS_SQLITE_HEX)],
    );

    let key = repo_key(Some("Shop"), "Order");
    // NOT refused : the reserved table/column names are legal quoted identifiers,
    // and the lifecycle-vs-attribute dedup kept CREATE TABLE single-columned.
    assert!(
        rt.repositories.get(&key).map(|r| r.is_adapter()).unwrap_or(false),
        "Order must be sqlite-backed (reserved words quoted, status deduped), not refused",
    );
    assert!(
        !rt.refused_persistence.contains_key(&key),
        "a quotable reserved-word schema must NOT be refused",
    );

    // Dispatch persists a row through the quoted upsert (INSERT ... `order` ...).
    rt.dispatch(
        "Shop::Order.Place",
        HashMap::from([("order".to_string(), Value::Str("A-1".into()))]),
    )
    .expect("Place must persist to the reserved-word `order` table");
    assert_eq!(rt.all("Order").len(), 1, "one Order persisted to sqlite");

    // Re-boot against the SAME db : load_persisted's quoted SELECT must read the
    // row back — exercises the reload path over reserved-word identifiers.
    let domain2 = storehouse::parser::parse(RESERVED_WORDS_BLUEBOOK);
    let rt2 = Runtime::boot_with_hecksagons(
        domain2,
        None,
        vec![hecksagon_parser::parse(RESERVED_WORDS_SQLITE_HEX)],
    );
    assert_eq!(
        rt2.all("Order").len(),
        1,
        "the Order reloads from sqlite on a fresh boot (quoted SELECT)",
    );
}

// ---- i735 defect 2 preserved : a GENUINELY incompatible schema (an
//      unopenable db) still refuses LOUDLY at boot instead of panicking ----

const UNOPENABLE_BLUEBOOK: &str = r#"Hecks.bluebook "Unopenable" do
      aggregate "Thing" do
        attribute :name, String
        command "Make" do
          attribute :name, String
        end
      end
    end
    "#;

// `db:` points at an existing DIRECTORY (`/tmp`), which sqlite cannot open as a
// database file — the factory's open() returns Err. This is the residual
// genuine-incompatibility case now that reserved words are handled by quoting.
const UNOPENABLE_SQLITE_HEX: &str =
    "Hecks.hecksagon \"Unopenable\" do\n  adapter :sqlite, db: \"/tmp\"\nend\n";

#[test]
fn an_unopenable_db_refuses_the_aggregate_without_panicking() {
    storehouse_sqlite::register();
    // Opening a directory as a sqlite db fails ; boot must NOT panic.
    let domain = storehouse::parser::parse(UNOPENABLE_BLUEBOOK);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(UNOPENABLE_SQLITE_HEX)],
    );

    let key = repo_key(Some("Unopenable"), "Thing");
    // REFUSED : no repository survives — never a silent heki swap (Decision 1).
    assert!(
        !rt.repositories.contains_key(&key),
        "a refused sqlite aggregate must have NO repository, never a silent heki swap",
    );
    // The loud reason is recorded for a dispatch to surface as PersistenceRefused.
    assert!(
        rt.refused_persistence.contains_key(&key),
        "the refusal must be recorded with a loud reason (i735 defect 2)",
    );

    // A dispatch against the refused aggregate returns the LOUD PersistenceRefused
    // error — never a panic, never a misleading UnknownAggregate.
    let err = rt
        .dispatch(
            "Unopenable::Thing.Make",
            HashMap::from([("name".to_string(), Value::Str("x".into()))]),
        )
        .expect_err("dispatch against a refused-persistence aggregate must error");
    assert!(
        matches!(err, RuntimeError::PersistenceRefused(_)),
        "expected PersistenceRefused, got {err:?}",
    );
}
