
use storehouse::heki::WriteContext;
use storehouse_sqlite::sql_type;
use storehouse_sqlite::SqliteRepository;
use storehouse::runtime::{AggregateState, Value};
use std::collections::HashMap;

fn tmp_db(name: &str) -> String {
    let p = std::env::temp_dir().join(format!("hecks_sqlite_test_{name}.db"));
    let _ = std::fs::remove_file(&p);
    p.to_string_lossy().into_owned()
}

#[test]
fn sql_type_map_mirrors_ruby() {
    assert_eq!(sql_type("String"), "VARCHAR(255)");
    assert_eq!(sql_type("Integer"), "INTEGER");
    assert_eq!(sql_type("Float"), "REAL");
    assert_eq!(sql_type("Boolean"), "BOOLEAN");
    assert_eq!(sql_type("TrueClass"), "BOOLEAN");
    assert_eq!(sql_type("FalseClass"), "BOOLEAN");
    assert_eq!(sql_type("Title"), "TEXT");
    assert_eq!(sql_type("PublishedAt"), "TEXT");
}

#[test]
fn save_then_find_round_trips_typed_columns() {
    let db = tmp_db("roundtrip");
    let cols = vec![
        ("title".to_string(), "TEXT".to_string()),
        ("status".to_string(), "TEXT".to_string()),
    ];
    let mut repo = SqliteRepository::new("BlogEntry", &db, None, cols).unwrap();
    let mut state = AggregateState::new("1");
    state.set("title", Value::Str("First Light".into()));
    state.set("status", Value::Str("published".into()));
    repo.save(state, WriteContext::OutOfBand { reason: "test" });

    let found = repo.find("1").expect("row should be found");
    assert_eq!(found.get("title").to_string(), "First Light");
    assert_eq!(found.get("status").to_string(), "published");
    assert_eq!(repo.count(), 1);
}

#[test]
fn cold_reopen_sees_persisted_rows_and_advances_next_id() {
    let db = tmp_db("cold");
    let cols = vec![("title".to_string(), "TEXT".to_string())];
    {
        let mut repo = SqliteRepository::new("BlogEntry", &db, None, cols.clone()).unwrap();
        let mut s = AggregateState::new("1");
        s.set("title", Value::Str("First".into()));
        repo.save(s, WriteContext::OutOfBand { reason: "test" });
    }
    let mut repo2 = SqliteRepository::new("BlogEntry", &db, None, cols).unwrap();
    assert_eq!(repo2.count(), 1, "reopened repo must see the persisted row");
    assert_eq!(repo2.find("1").unwrap().get("title").to_string(), "First");
    let minted = repo2.id_for_command(&HashMap::new());
    assert_eq!(minted, "2");
}
