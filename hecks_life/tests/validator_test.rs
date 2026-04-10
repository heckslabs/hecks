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
    let domain = parse_file("../hecks_conception/nursery/pizzas/pizzas.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "pizzas errors: {:?}", errors);
}

#[test]
fn veterinary_domain_is_valid() {
    let domain = parse_file("../hecks_conception/nursery/veterinary/veterinary.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "veterinary errors: {:?}", errors);
}

#[test]
fn life_domain_is_valid() {
    let domain = parse_file("../hecks_conception/nursery/hecks/life.bluebook");
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "life errors: {:?}", errors);
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
    let domain = parser::parse(r#"Hecks.bluebook "Bad" do
  aggregate "Widget" do
    description "A widget"
    command "WidgetThing" do
      role "User"
    end
  end
end"#);
    let errors = validator::validate(&domain);
    assert!(errors.iter().any(|e| e.contains("doesn't start with a verb")));
}
