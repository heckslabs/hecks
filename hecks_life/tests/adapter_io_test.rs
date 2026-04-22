//! Pin substitution + option parsing for the tiny I/O adapters.
//!
//! The actual stdout/stderr/stdin writes are exercised by integration
//! tests on `hecks-life run`; these unit tests nail down the parts
//! that don't touch real I/O.

use hecks_life::hecksagon_ir::IoAdapter;
use hecks_life::runtime::adapter_io::{substitute, read_env};
use std::collections::HashMap;

#[test]
fn substitute_replaces_placeholders_and_keeps_unknowns() {
    let mut attrs = HashMap::new();
    attrs.insert("name".into(), "Miette".into());
    assert_eq!(substitute("hello {{name}}", &attrs), "hello Miette");
    assert_eq!(substitute("unknown {{other}}", &attrs), "unknown {{other}}");
    assert_eq!(substitute("no placeholders", &attrs), "no placeholders");
}

#[test]
fn substitute_handles_multiple_tokens() {
    let mut attrs = HashMap::new();
    attrs.insert("a".into(), "1".into());
    attrs.insert("b".into(), "2".into());
    assert_eq!(substitute("{{a}}-{{b}}-{{a}}", &attrs), "1-2-1");
}

#[test]
fn read_env_looks_up_declared_keys() {
    let adapter = IoAdapter {
        kind: "env".into(),
        options: vec![("keys".into(), r#"["HECKS_ADAPTER_IO_TEST_SET"]"#.into())],
        on_events: vec![],
    };
    std::env::set_var("HECKS_ADAPTER_IO_TEST_SET", "yes");
    let map = read_env(&adapter);
    assert_eq!(map.get("HECKS_ADAPTER_IO_TEST_SET"), Some(&"yes".to_string()));
    std::env::remove_var("HECKS_ADAPTER_IO_TEST_SET");
}

#[test]
fn read_env_returns_empty_string_for_missing_keys() {
    let adapter = IoAdapter {
        kind: "env".into(),
        options: vec![("keys".into(), r#"["HECKS_DEFINITELY_NOT_SET_XYZ"]"#.into())],
        on_events: vec![],
    };
    let map = read_env(&adapter);
    assert_eq!(map.get("HECKS_DEFINITELY_NOT_SET_XYZ"), Some(&"".to_string()));
}
