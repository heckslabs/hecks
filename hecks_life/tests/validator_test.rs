//! Validator integration tests
//!
//! Validates nursery domains and exercises error detection.

use hecks_life::parser;
use hecks_life::validator;

fn parse_file(rel_path: &str) -> hecks_life::ir::Domain {
    let path = format!("{}/{}", env!("CARGO_MANIFEST_DIR"), rel_path);
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Cannot read {}: {}", path, e));
    parser::parse(&source)
}

#[test]
fn pizzas_domain_is_valid() {
    let domain = parse_file("../hecks_conception/catalog/pizzas.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "pizzas errors: {:?}", errors);
}

#[test]
fn veterinary_clinic_domain_is_valid() {
    let domain = parse_file("../hecks_conception/nursery/veterinary_clinic/veterinary_clinic.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "veterinary_clinic errors: {:?}", errors);
}

#[test]
fn mind_domain_is_valid() {
    // Replaces the deleted `nursery/hecks/life` self-hosting fixture
    // with the catalog/mind chapter — large, lifecycle-heavy domain
    // that exercises the validator across all check categories.
    let domain = parse_file("../hecks_conception/catalog/mind.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "mind errors: {:?}", errors);
}

#[test]
fn detects_commandless_aggregate() {
    let domain = parser::parse(r#"Hecks.bluebook "Bad" do
  aggregate "Empty" do
    description "No commands"
    attribute :name
  end
end"#);
    let errors = validator::validate(&domain);
    assert!(errors.iter().any(|e| e.contains("Empty has no commands")));
}

#[test]
fn detects_bad_reference() {
    let domain = parser::parse(r#"Hecks.bluebook "Bad" do
  aggregate "Order" do
    description "An order"
    reference_to Ghost
    command "PlaceOrder" do
      role "Customer"
    end
  end
end"#);
    let errors = validator::validate(&domain);
    assert!(errors.iter().any(|e| e.contains("unknown aggregate: Ghost")));
}

#[test]
fn detects_bad_policy_trigger() {
    let domain = parser::parse(r#"Hecks.bluebook "Bad" do
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
      emits "OrderPlaced"
    end
  end
  policy "Ghost" do
    on "OrderPlaced"
    trigger "NonexistentCommand"
  end
end"#);
    let errors = validator::validate(&domain);
    assert!(errors.iter().any(|e| e.contains("triggers unknown command")));
}

#[test]
fn detects_non_verb_command() {
    // First-word-only check: "Configuration" starts the command and
    // ends in a noun suffix ("tion") that's not in the verb-exception
    // list. Compare with `WidgetThing` — first_word is "Widget", which
    // has no noun/adjective suffix, so the validator can't tell.
    let domain = parser::parse(r#"Hecks.bluebook "Bad" do
  aggregate "Widget" do
    description "A widget"
    command "ConfigurationWidget" do
      role "User"
    end
  end
end"#);
    let errors = validator::validate(&domain);
    assert!(errors.iter().any(|e| e.contains("commands should start with a verb")));
}
