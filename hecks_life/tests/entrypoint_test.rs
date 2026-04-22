//! Parser recognizes `entrypoint "CommandName"` as a top-level declaration
//! inside `Hecks.bluebook "…" do … end`.
//!
//! This is the command `hecks-life run <file>` dispatches when the
//! bluebook is invoked as an executable via its shebang line.

use hecks_life::parser;

const WITH_ENTRYPOINT: &str = r#"
Hecks.bluebook "Greeter" do
  entrypoint "SayHello"
  aggregate "Session" do
    command "SayHello"
  end
end
"#;

const WITHOUT_ENTRYPOINT: &str = r#"
Hecks.bluebook "Silent" do
  aggregate "Session" do
    command "SayHello"
  end
end
"#;

#[test]
fn parses_entrypoint_as_option_string() {
    let with = parser::parse(WITH_ENTRYPOINT);
    assert_eq!(with.entrypoint.as_deref(), Some("SayHello"));
}

#[test]
fn missing_entrypoint_is_none() {
    let without = parser::parse(WITHOUT_ENTRYPOINT);
    assert!(without.entrypoint.is_none());
}
