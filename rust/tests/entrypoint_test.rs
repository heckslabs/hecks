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

// --- Section composition (i105) -----------------------------------------

const WITH_SECTIONS: &str = r#"
Hecks.bluebook "Status" do
  entrypoint "GenerateReport"

  aggregate "StatusReport" do
    description "snapshot"
  end

  section "Identity" do
    row "name", :identity_name
    row "born", :born_at
  end

  section "Vitals" do
    row "fatigue", :fatigue
    row "cycle",   :cycle
  end
end
"#;

#[test]
fn parses_sections_with_rows() {
    let d = parser::parse(WITH_SECTIONS);
    assert_eq!(d.sections.len(), 2);
    assert_eq!(d.sections[0].title, "Identity");
    assert_eq!(d.sections[0].rows.len(), 2);
    assert_eq!(d.sections[0].rows[0].label, "name");
    assert_eq!(d.sections[0].rows[0].field, "identity_name");
    assert_eq!(d.sections[0].rows[1].label, "born");
    assert_eq!(d.sections[0].rows[1].field, "born_at");
    assert_eq!(d.sections[1].title, "Vitals");
    assert_eq!(d.sections[1].rows.len(), 2);
    assert_eq!(d.sections[1].rows[1].field, "cycle");
}

#[test]
fn missing_sections_is_empty_vec() {
    let d = parser::parse(WITHOUT_ENTRYPOINT);
    assert!(d.sections.is_empty());
}

#[test]
fn empty_section_block_parses_with_no_rows() {
    let src = r#"
Hecks.bluebook "Empty" do
  section "Header only" do
  end
end
"#;
    let d = parser::parse(src);
    assert_eq!(d.sections.len(), 1);
    assert_eq!(d.sections[0].title, "Header only");
    assert!(d.sections[0].rows.is_empty());
}
