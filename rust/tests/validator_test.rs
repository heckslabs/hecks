//! Validator integration tests
//!
//! Validates nursery domains and exercises error detection.
//!
//! [antibody-exempt: rust/tests/validator_test.rs — kernel-surface
//!  smoke that the validator passes on shipped exemplar bluebooks
//!  (pizzas, mind) and exercises detection on hand-built bad domains.
//!  Test-only kernel surface. Retires when the behaviors framework
//!  gains a validator-output-assertion vocabulary (filed as i569 —
//!  the lowest-friction first step in the cluster, since it can
//!  reuse the existing `.behaviors` Domain-literal parsing).]

use storehouse::parser;
use storehouse::validator;

fn parse_file(rel_path: &str) -> storehouse::ir::Domain {
    let path = format!("{}/{}", env!("CARGO_MANIFEST_DIR"), rel_path);
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Cannot read {}: {}", path, e));
    parser::parse(&source)
}

#[test]
fn pizzas_domain_is_valid() {
    let domain = parse_file("../hecks_conception/catalog/pizzas.bluebook");
    let errors = validator::validate(&domain);
    // "uses primitive type" errors are filtered : the no_primitive_envy
    // rule is intentionally strict, but the existing bluebooks (pizzas,
    // mind, veterinary_clinic) carry known migration debt tracked in
    // inbox/i102 (primitive-envy-sweep-bluebooks-to-value-objects). This
    // test checks for OTHER validator failures (commandless aggregates,
    // bad references, non-verb commands, …) while the i102 sweep is
    // pending. When i102 lands, drop this filter.
    let migration_pending: Vec<&String> = errors.iter()
        .filter(|e| !e.contains("uses primitive type"))
        .collect();
    assert!(migration_pending.is_empty(), "pizzas non-debt errors: {:?}", migration_pending);
}

#[test]
fn veterinary_clinic_domain_is_valid() {
    // The nursery migrated to its own repo (chrisyoung/hecks_nursury) on
    // 2026-04-30 — see commit ecb14688. veterinary_clinic now lives there
    // as a sibling-repo fixture. The relative path reaches it through the
    // standard local layout (~/Projects/hecks/ + ~/Projects/hecks_nursury/).
    //
    // Skip silently when the sibling repo isn't checked out (CI runners
    // that don't clone hecks_nursury, contributors who haven't pulled it).
    // Coverage retains via local pre-push when the sibling is present.
    let rel = "../../hecks_nursury/veterinary_clinic/veterinary_clinic.bluebook";
    let abs = format!("{}/{}", env!("CARGO_MANIFEST_DIR"), rel);
    if !std::path::Path::new(&abs).exists() {
        eprintln!("skipping veterinary_clinic — sibling repo hecks_nursury not checked out");
        return;
    }
    let domain = parse_file(rel);
    let errors = validator::validate(&domain);
    // See pizzas_domain_is_valid for the i102 migration-debt rationale.
    let migration_pending: Vec<&String> = errors.iter()
        .filter(|e| !e.contains("uses primitive type"))
        .collect();
    assert!(migration_pending.is_empty(), "veterinary_clinic non-debt errors: {:?}", migration_pending);
}

#[test]
fn mind_domain_is_valid() {
    // Replaces the deleted `nursery/hecks/life` self-hosting fixture
    // with the catalog/mind chapter — large, lifecycle-heavy domain
    // that exercises the validator across all check categories.
    let domain = parse_file("../hecks_conception/catalog/mind.bluebook");
    let errors = validator::validate(&domain);
    // See pizzas_domain_is_valid for the i102 migration-debt rationale.
    let migration_pending: Vec<&String> = errors.iter()
        .filter(|e| !e.contains("uses primitive type"))
        .collect();
    assert!(migration_pending.is_empty(), "mind non-debt errors: {:?}", migration_pending);
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
