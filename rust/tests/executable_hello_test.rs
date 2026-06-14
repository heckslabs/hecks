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
    // Isolate persistence to a tempdir so running the example does NOT write
    // hello.heki into the live info_dir (miette-state/information). run_script
    // persists through resolve_info_dir, which honours HECKS_INFO ; without this
    // the Greet dispatch polluted Miette's live store every test run (i728 G3).
    let tmp = std::env::temp_dir().join(format!("hello_test_{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let prev = std::env::var("HECKS_INFO").ok();
    std::env::set_var("HECKS_INFO", tmp.to_string_lossy().to_string());

    let path = hello_path().to_string_lossy().into_owned();
    let args = vec!["storehouse".into(), "run".into(), path];
    let code = run::run_script(&args);

    match &prev {
        Some(v) => std::env::set_var("HECKS_INFO", v),
        None => std::env::remove_var("HECKS_INFO"),
    }
    let _ = std::fs::remove_dir_all(&tmp);
    assert_eq!(code, ExitKind::Ok.code());
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
