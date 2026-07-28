
use std::collections::HashMap;
use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{repo_key, Runtime, RuntimeError, Value};

fn aggregates_dir() -> String {
    format!("{}/aggregates", storehouse::storehouse_router::conception_root())
}

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

    let git_repo = rt
        .repositories
        .get(&repo_key(Some("Git"), "Git"))
        .expect("Git::Git repository present in the combined domain");
    assert!(
        git_repo.is_adapter(),
        "Git context must be SQL-backed by its own :sqlite hecksagon",
    );

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
    let _ = std::fs::remove_file("/tmp/quoted_reserved_words.db");
    let domain = storehouse::parser::parse(RESERVED_WORDS_BLUEBOOK);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(RESERVED_WORDS_SQLITE_HEX)],
    );

    let key = repo_key(Some("Shop"), "Order");
    assert!(
        rt.repositories.get(&key).map(|r| r.is_adapter()).unwrap_or(false),
        "Order must be sqlite-backed (reserved words quoted, status deduped), not refused",
    );
    assert!(
        !rt.refused_persistence.contains_key(&key),
        "a quotable reserved-word schema must NOT be refused",
    );

    rt.dispatch(
        "Shop::Order.Place",
        HashMap::from([("order".to_string(), Value::Str("A-1".into()))]),
    )
    .expect("Place must persist to the reserved-word `order` table");
    assert_eq!(rt.all("Order").len(), 1, "one Order persisted to sqlite");

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


const UNOPENABLE_BLUEBOOK: &str = r#"Hecks.bluebook "Unopenable" do
      aggregate "Thing" do
        attribute :name, String
        command "Make" do
          attribute :name, String
        end
      end
    end
    "#;

const UNOPENABLE_SQLITE_HEX: &str =
    "Hecks.hecksagon \"Unopenable\" do\n  adapter :sqlite, db: \"/tmp\"\nend\n";

#[test]
fn an_unopenable_db_refuses_the_aggregate_without_panicking() {
    storehouse_sqlite::register();
    let domain = storehouse::parser::parse(UNOPENABLE_BLUEBOOK);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(UNOPENABLE_SQLITE_HEX)],
    );

    let key = repo_key(Some("Unopenable"), "Thing");
    assert!(
        !rt.repositories.contains_key(&key),
        "a refused sqlite aggregate must have NO repository, never a silent heki swap",
    );
    assert!(
        rt.refused_persistence.contains_key(&key),
        "the refusal must be recorded with a loud reason (i735 defect 2)",
    );

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
