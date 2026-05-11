//! Smoke test that the shipped antibody.hecksagon parses non-empty.
//!
//! [antibody-exempt: rust/tests/antibody_hecksagon_test.rs — kernel-
//!  surface smoke that the antibody capability's hecksagon parses.
//!  Runtime file read against the shipped fixture. Test-only kernel
//!  surface. Retires when behaviors framework can drive hecksagon
//!  smoke tests directly.]

use storehouse::hecksagon_parser;
use std::fs;

#[test]
fn real_antibody_hecksagon_parses_non_empty() {
    let src = fs::read_to_string("../discipline/antibody/antibody.hecksagon").expect("cannot find antibody.hecksagon");
    let hex = hecksagon_parser::parse(&src);
    assert_eq!(hex.name, "Antibody");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    assert_eq!(hex.shell_adapters.len(), 7);
    assert_eq!(hex.gates.len(), 3);
}
