//! Runs only when a Postgres server is reachable on localhost — the same
//! gate the Ruby adapter spec and `bin/parity`'s postgres variant use.
//! Absent a server, every test here passes with a printed notice rather
//! than failing a machine that has no infrastructure.

use postgres::{Client, NoTls};
use storehouse::heki::WriteContext;
use storehouse::runtime::PersistenceAdapter;
use storehouse::runtime::{AggregateState, Value};
use storehouse_postgres::PostgresRepository;

const TEST_DB: &str = "hecksagain_rust_adapter_test";

fn admin() -> Option<Client> {
    Client::connect("host=localhost dbname=postgres", NoTls).ok()
}

/// A fresh scratch database, or None (with a notice) when no server is
/// reachable.
fn fresh_database(client: &mut Client) -> String {
    let _ = client.batch_execute(&format!("DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)"));
    client
        .batch_execute(&format!("CREATE DATABASE {TEST_DB}"))
        .expect("cannot create scratch database");
    TEST_DB.to_string()
}

#[test]
fn journal_head_round_trip_cold_reopen_and_query_pushdown() {
    let Some(mut admin) = admin() else {
        eprintln!("no reachable Postgres — start one to run this test");
        return;
    };
    let database = fresh_database(&mut admin);

    {
        let mut repository = PostgresRepository::new("BlogEntry", &database, "").unwrap();
        let mut state = AggregateState::new("1");
        state.set("title", Value::Str("First Light".into()));
        state.set("status", Value::Str("published".into()));
        let mut price = std::collections::HashMap::new();
        price.insert("cents".to_string(), Value::Int(1200));
        state.set("price", Value::Map(price));
        repository
            .save(state, WriteContext::OutOfBand { reason: "test" })
            .unwrap();

        let found = repository.find("1").expect("row should be found");
        assert_eq!(found.get("title").to_string(), "First Light");
        assert_eq!(repository.count(), 1);

        let entries = repository.replication_entries().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].operation, "save");

        // second write to the same id: journal grows, head replaces
        let mut updated = AggregateState::new("1");
        updated.set("title", Value::Str("First Light".into()));
        updated.set("status", Value::Str("archived".into()));
        repository
            .save(updated, WriteContext::OutOfBand { reason: "test" })
            .unwrap();
        assert_eq!(repository.count(), 1);
        assert_eq!(repository.replication_entries().unwrap().len(), 2);
    }

    // cold reopen — the head survives the adapter that wrote it
    let mut reopened = PostgresRepository::new("BlogEntry", &database, "").unwrap();
    assert_eq!(reopened.count(), 1);
    assert_eq!(reopened.find("1").unwrap().get("status").to_string(), "archived");

    // query pushdown: compiles the comparison into jsonb SQL
    use storehouse::ir::{WhereClause, WhereOp};
    let wheres = vec![WhereClause {
        field: "price.cents".to_string(),
        op: WhereOp::Lt,
        value: "1500".to_string(),
    }];
    let rows = reopened.query(&wheres, &std::collections::HashMap::new()).unwrap();
    assert_eq!(rows.len(), 0, "the archived head no longer carries price after replacement");

    let wheres = vec![WhereClause {
        field: "status".to_string(),
        op: WhereOp::Eq,
        value: "archived".to_string(),
    }];
    let rows = reopened.query(&wheres, &std::collections::HashMap::new()).unwrap();
    assert_eq!(rows.len(), 1);

    // in/none_in_state cannot compile fully — pushdown declines outright
    let wheres = vec![WhereClause {
        field: "status".to_string(),
        op: WhereOp::In,
        value: "archived".to_string(),
    }];
    assert!(reopened.query(&wheres, &std::collections::HashMap::new()).is_none());

    // delete goes through the journal and the head
    reopened.delete("1", WriteContext::OutOfBand { reason: "test" }).unwrap();
    assert!(reopened.find("1").is_none());
    let entries = reopened.replication_entries().unwrap();
    assert_eq!(entries.last().unwrap().operation, "delete");

    let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)"));
}

#[test]
fn refuses_a_missing_database_and_an_unreachable_one() {
    let spec = storehouse::runtime::PersistenceSpec {
        aggregate: storehouse::parser::parse("Hecks.bluebook \"B\" do\n  aggregate \"BlogEntry\" do\n  end\nend\n")
            .aggregates
            .remove(0),
        options: std::collections::HashMap::new(),
    };
    let refusal = storehouse_postgres::postgres_factory(&spec).err().unwrap();
    assert_eq!(
        refusal,
        "BlogEntry binds Postgres, which needs a database connection, but its world declares no \"database\"."
    );

    let unreachable = PostgresRepository::new("BlogEntry", "postgres://localhost:1/nowhere", "").err().unwrap();
    assert!(
        unreachable.starts_with("cannot bind Postgres at postgres://localhost:1/nowhere for BlogEntry:"),
        "got {unreachable}"
    );
}

/// The Rust side of the Postgres era gate: recognize stored eras
/// structurally, hold era 1 on first boot, refuse toward the Ruby
/// scaffold on anything unminted. The no-edge and superseded refusals
/// are byte-identical with the Ruby manager's
/// (spec/adapters/postgres_lineage_spec.rb pins the same strings).
#[test]
fn era_gate_recognizes_holds_and_refuses_toward_the_ruby_scaffold() {
    let Some(mut admin) = admin() else {
        eprintln!("no reachable Postgres — start one to run this test");
        return;
    };
    const GATE_DB: &str = "hecksagain_rust_gate_test";
    let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {GATE_DB} WITH (FORCE)"));
    admin.batch_execute(&format!("CREATE DATABASE {GATE_DB}")).unwrap();

    let v1 = "Hecks.bluebook \"Ledger\" do\n  aggregate \"Account\" do\n    attribute :cost, Money\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n";
    let v2 = "Hecks.bluebook \"Ledger\" do\n  aggregate \"Account\" do\n    attribute :amount, Money\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n";

    let mut repository = PostgresRepository::new("Account", GATE_DB, "Ledger").unwrap();
    let v1_shape = storehouse_postgres::shape_of(v1);
    let v2_shape = storehouse_postgres::shape_of(v2);

    // first boot holds era 1 as a row
    assert_eq!(repository.era_gate("Ledger", v1, &v1_shape, &[]).unwrap(), Some(1));
    let mut check = Client::connect(&format!("host=localhost dbname={GATE_DB}"), NoTls).unwrap();
    let held: String = check.query_one("SELECT held_text FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 1", &[]).unwrap().get(0);
    assert_eq!(held, v1);

    // the same shape boots quietly, even under textual (behavioral) edits
    assert_eq!(repository.era_gate("Ledger", v1, &v1_shape, &[]).unwrap(), Some(1));

    // drift with no covering edge — byte-identical with the Ruby refusal
    let refusal = repository.era_gate("Ledger", v2, &v2_shape, &[]).unwrap_err();
    assert_eq!(
        refusal,
        "cannot boot Ledger: the shape changed (era 2) and no translation edge covers it — run bin/scaffold_translation to write the edge, check it with bin/translation_audit, then boot again"
    );

    // once the era has a minted hash and an edge leaves it, this side
    // still refuses: minting is Ruby-only
    check.execute("UPDATE hecks_eras SET hash = 'aaaa11', label = 'aaaa11' WHERE domain = 'Ledger'", &[]).unwrap();
    let edge = storehouse::bluebook::translation::parser::parse(
        "Hecks.data_translation \"Ledger\", from: \"aaaa11\", to: \"bbbb22\" do\n  aggregate \"Account\" do\n    rename :cost, to: :amount\n  end\nend\n",
    )
    .unwrap();
    let refusal = repository.era_gate("Ledger", v2, &v2_shape, &[edge]).unwrap_err();
    assert_eq!(
        refusal,
        "cannot boot Ledger: era 2 is not minted — minting is Ruby-only; boot the domain from Ruby to mint it, then boot here again"
    );

    // a superseded era's shape is recognized and PERMITTED — the old
    // world keeps booting its own era, and adopts it for its writes
    check
        .execute(
            "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark) VALUES ('Ledger', 2, 'bbbb22', 'bbbb22', $1, 0)",
            &[&v2],
        )
        .unwrap();
    assert_eq!(repository.era_gate("Ledger", v1, &v1_shape, &[]).unwrap(), Some(1));
    repository.adopt_era(1);

    // an edited held text refuses in the pinned words — and says WHICH
    // situation the operator is in (this edit changes the shape)
    check
        .execute("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", &[&v2])
        .unwrap();
    let refusal = repository.era_gate("Ledger", v1, &v1_shape, &[]).unwrap_err();
    assert_eq!(
        refusal,
        "cannot boot Ledger: the held text of era 1 was edited after it was frozen AND the edit changed the storage shape — re-attestation will refuse it; restore the original text from the era archive"
    );
    // ...and the archive still holds the original for recovery
    let archived: String = check
        .query_one("SELECT held_text FROM hecks_era_texts WHERE domain = 'Ledger' AND ordinal = 1", &[])
        .unwrap()
        .get(0);
    assert_eq!(archived, v1);
    check
        .execute("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", &[&archived])
        .unwrap();

    drop(check);
    drop(repository);
    let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {GATE_DB} WITH (FORCE)"));
}

/// The enforcement-grade adapter refuses to be ephemeral, in so many
/// words — byte-identical with the Ruby gate's refusal.
#[test]
fn postgres_refuses_a_declared_ephemeral_world() {
    let Some(mut admin) = admin() else {
        eprintln!("no reachable Postgres — start one to run this test");
        return;
    };
    const EPHEMERAL_DB: &str = "hecksagain_rust_ephemeral_test";
    let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {EPHEMERAL_DB} WITH (FORCE)"));
    admin.batch_execute(&format!("CREATE DATABASE {EPHEMERAL_DB}")).unwrap();

    let root = std::env::temp_dir().join(format!("hecks-pg-ephemeral-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let bluebook_dir = root.join("bluebook");
    std::fs::create_dir_all(&bluebook_dir).unwrap();
    std::fs::write(
        bluebook_dir.join("iter.bluebook"),
        "Hecks.bluebook \"Iter\" do\n  aggregate \"Sketch\" do\n    attribute :cost, Money\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n",
    )
    .unwrap();
    std::fs::write(
        bluebook_dir.join("iter.world"),
        format!("Hecks.world \"Iter\" do\n  realm \"Examples\"\n  persisted_by(\"Postgres\") do\n    database \"{EPHEMERAL_DB}\"\n    eras \"ephemeral\"\n  end\nend\n"),
    )
    .unwrap();
    std::fs::write(
        bluebook_dir.join("iter.hecksagon"),
        "Hecks.hecksagon \"Iter\" do\n  Iter::Sketch.persisted_by(\"Postgres\")\nend\n",
    )
    .unwrap();

    storehouse_postgres::register();
    let refusal = storehouse::dispatcher::Runtime::boot(bluebook_dir.join("iter.bluebook")).err().unwrap();
    assert_eq!(
        refusal,
        "Iter binds Postgres with eras \"ephemeral\" — the enforcement-grade adapter never forgets an era; drop the setting, or bind a file adapter for iteration"
    );

    let _ = std::fs::remove_dir_all(&root);
    let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {EPHEMERAL_DB} WITH (FORCE)"));
}
