
use std::path::PathBuf;

fn fixture() -> String {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repo root above rust/")
        .join("spec/parity/fixtures/ruby_written.heki");

    root.to_string_lossy().to_string()
}

#[test]
fn reads_a_store_ruby_wrote() {
    let store = storehouse::heki::read(&fixture()).expect("ruby's heki file should read here");

    assert_eq!(store.len(), 2, "both records survived the crossing");

    let margherita = store.get("p1").expect("p1 present");
    assert_eq!(margherita.get("name").and_then(|v| v.as_str()), Some("Margherita"));

    assert_eq!(margherita.get("price_cents").and_then(|v| v.as_i64()), Some(1200));
    assert!(margherita.get("toppings").map(|v| v.is_array()).unwrap_or(false));
}

#[test]
fn refuses_a_file_that_is_not_heki() {
    let path = std::env::temp_dir().join("hecksagain-not-heki.heki");
    std::fs::write(&path, b"NOPE\x00\x00\x00\x00rest").expect("write probe");

    let error = storehouse::heki::read(&path.to_string_lossy()).expect_err("bad magic refuses");
    assert!(error.contains("bad magic"), "got: {}", error);

    let _ = std::fs::remove_file(&path);
}
