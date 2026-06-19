//! Integration test — the `examples/executable/hello.bluebook` example
//! actually runs end-to-end through `storehouse::run::run_script`.
//!
//! Pins the executable-bluebook acceptance from i649 (the shebang +
//! companion .hecksagon + dispatch path) against the on-disk example
//! so future parser / runner edits cannot regress it silently.
//!
//! The shebang line itself is exercised by `shebang_test.rs` ; this
//! test asserts the full script-mode invocation lands `ExitKind::Ok`
//! and the companion hecksagon parses with the expected adapters.

use storehouse::run::{self, ExitKind};

use std::path::PathBuf;

fn hello_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop(); // rust/ → repo root
    p.push("examples/executable/hello.bluebook");
    p
}

#[test]
fn hello_example_exists_on_disk() {
    let p = hello_path();
    assert!(p.exists(), "examples/executable/hello.bluebook missing at {:?}", p);
}

#[test]
fn hello_example_starts_with_a_shebang() {
    let src = std::fs::read_to_string(hello_path()).unwrap();
    assert!(
        src.starts_with("#!/usr/bin/env storehouse run\n"),
        "hello.bluebook missing the canonical executable shebang"
    );
}

#[test]
fn hello_example_runs_to_completion() {
    // hello declares no world, so run_script boots it IN MEMORY — nothing
    // touches disk, so there is no live store to pollute and nothing to
    // isolate (the reason this test no longer needs HECKS_INFO / a tempdir).
    let path = hello_path().to_string_lossy().into_owned();
    let args = vec!["storehouse".into(), "run".into(), path];
    assert_eq!(run::run_script(&args), ExitKind::Ok.code());
}

#[test]
fn hello_example_loads_companion_hecksagon() {
    let path = hello_path().to_string_lossy().into_owned();
    let (domain, hex) = run::load_script(&path).unwrap();
    assert_eq!(domain.name, "Hello");
    assert_eq!(domain.entrypoint.as_deref(), Some("Greet"));
    assert_eq!(hex.name, "Hello");
    assert!(hex.io_adapter("stdout").is_some(),
            "hello.hecksagon must declare a :stdout adapter");
}
