//! The heki FORMAT is a contract between two runtimes, so it is tested across
//! them rather than within one.
//!
//! The fixture at spec/parity/fixtures/ruby_written.heki was written by RUBY's
//! adapter, byte for byte. Reading it here proves the two implementations agree
//! about what a .heki file IS — which round-tripping cannot, because a format
//! that only round-trips through itself is two formats wearing one extension,
//! and the day that surfaces is the day someone switches runtimes on a
//! directory that already has data in it.
//!
//! What is NOT claimed : byte-identity. Rust's Store is a HashMap, so serde
//! emits its keys in whatever order the map iterates and two Rust runs over the
//! same records need not produce the same file. Ruby sorts, which makes ITS
//! output reproducible ; nothing on this side can make the bytes match. Compare
//! decoded stores, never files.

use std::path::PathBuf;

fn fixture() -> String {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
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

    // The types survive too. A price that arrived as the STRING "1200" would
    // still look right in a listing and compare wrong in every given.
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
