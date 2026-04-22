use hecks_life::hecksagon_parser;
use std::fs;

#[test]
fn real_antibody_hecksagon_parses_non_empty() {
    let src = fs::read_to_string("../hecks_conception/capabilities/antibody/antibody.hecksagon").expect("cannot find antibody.hecksagon");
    let hex = hecksagon_parser::parse(&src);
    assert_eq!(hex.name, "Antibody");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    assert_eq!(hex.shell_adapters.len(), 7);
    assert_eq!(hex.gates.len(), 3);
}
