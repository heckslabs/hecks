//! IO validator tests
//!
//! Locks the contract: bluebooks are in-memory by default. The
//! runtime-smoke layer must always pass for a pure bluebook; the
//! static-scan layer must reliably warn on IO-suggestive patterns.

use hecks_life::io_validator::{check, Severity};
use hecks_life::parser;

#[test]
fn pure_bluebook_passes_runtime_smoke() {
    let source = r#"Hecks.bluebook "Pure" do
  vision "no IO anywhere"
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
      emits "PizzaCreated"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(domain);
    assert_eq!(report.errors(), 0,
        "pure bluebook produced runtime errors: {:?}",
        report.runtime_findings.iter().map(|f| &f.message).collect::<Vec<_>>());
    // Static scan should NOT flag a Create command for the
    // "emits but no mutations" rule (Create auto-bootstraps state).
    assert_eq!(report.warnings(), 0,
        "Create command should not be flagged as pure-side-effect");
}

#[test]
fn deploy_command_warns_in_static_scan() {
    let source = r#"Hecks.bluebook "Risky" do
  vision "has a Deploy command"
  aggregate "Site" do
    attribute :url, String
    command "DeploySite" do
      attribute :url, String
      emits "SiteDeployed"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(domain);
    // Static scan flags both: command name AND past-tense event name.
    // No runtime errors — the dispatch itself doesn't actually do IO,
    // only the names imply it.
    assert!(report.warnings() >= 1, "expected at least one warning");
    assert_eq!(report.errors(), 0, "names alone shouldn't be errors");
    assert!(
        report.static_findings.iter()
            .any(|f| f.message.contains("Deploy")),
        "should flag the Deploy command name",
    );
}

#[test]
fn lifecycle_command_is_not_flagged_as_pure_side_effect() {
    // CancelOrder has no then_set — its job is to trigger the
    // lifecycle transition. Validator must NOT flag this as
    // "pure side-effect" (the lifecycle is the side effect).
    let source = r#"Hecks.bluebook "Orders" do
  aggregate "Order" do
    attribute :customer, String
    attribute :status, String
    command "PlaceOrder" do
      attribute :customer, String
      emits "OrderPlaced"
    end
    command "CancelOrder" do
      reference_to(Order)
      emits "OrderCancelled"
    end
    lifecycle :status, default: "pending" do
      transition "CancelOrder" => "cancelled"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(domain);
    let cancel_warn = report.static_findings.iter()
        .any(|f| f.location.contains("CancelOrder") && f.message.contains("pure side-effect"));
    assert!(!cancel_warn,
        "CancelOrder should not be flagged — its effect is the lifecycle transition");
}

#[test]
fn pure_side_effect_command_is_flagged() {
    // A command that emits but has no mutations, no givens, no lifecycle
    // membership, and is not a create — this is the hard case the
    // validator cares about. Send-style commands.
    let source = r#"Hecks.bluebook "Ringer" do
  aggregate "Bell" do
    attribute :name, String
    command "Ring" do
      emits "Rang"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(domain);
    let flagged = report.static_findings.iter()
        .any(|f| f.severity == Severity::Warning && f.location.contains("Ring") && f.message.contains("pure side-effect"));
    assert!(flagged, "Ring is a pure side-effect command — should be flagged");
}

#[test]
fn pascal_prefix_doesnt_misfire_on_substring() {
    // `Pulse` starts with "Pul" but should NOT match "Pull".
    let source = r#"Hecks.bluebook "Heart" do
  aggregate "Heart" do
    attribute :rate, Integer
    command "PulseHeart" do
      attribute :rate, Integer
      emits "HeartPulsed"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(domain);
    let misfire = report.static_findings.iter()
        .any(|f| f.message.contains("\"Pull\""));
    assert!(!misfire, "PulseHeart should not match Pull prefix");
}
