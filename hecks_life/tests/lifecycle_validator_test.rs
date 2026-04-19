//! Lifecycle validator tests
//!
//! Locks the contract: a transition's from_state must be reachable
//! from the lifecycle default; otherwise it's dead and the validator
//! flags it. Stuck-default warns.

use hecks_life::lifecycle_validator::{check, Severity};
use hecks_life::parser;

#[test]
fn flags_unreachable_from_state() {
    // Classic bug: default is "active", but a transition wants "none"
    // as from_state. Nothing transitions to "none" → dead.
    let source = r#"Hecks.bluebook "Buggy" do
  aggregate "Record" do
    attribute :status, String
    command "OpenRecord" do
      attribute :name, String
      emits "RecordOpened"
    end
    lifecycle :status, default: "active" do
      transition "OpenRecord" => "active", from: "none"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 1, "expected one unreachable-from error");
    assert!(report.findings[0].location.contains("OpenRecord"));
    assert!(report.findings[0].message.contains("unreachable"));
}

#[test]
fn pass_when_from_state_is_default() {
    // The simplest valid lifecycle: from_state matches the default.
    let source = r#"Hecks.bluebook "OK" do
  aggregate "Order" do
    attribute :status, String
    command "PlaceOrder" do
      emits "OrderPlaced"
    end
    command "CancelOrder" do
      reference_to(Order)
      emits "OrderCancelled"
    end
    lifecycle :status, default: "pending" do
      transition "CancelOrder" => "cancelled", from: "pending"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 0, "expected no errors: {:?}",
        report.findings.iter().map(|f| &f.message).collect::<Vec<_>>());
}

#[test]
fn pass_when_from_state_is_other_to_state() {
    // Multi-step: the from_state of step 2 is the to_state of step 1.
    let source = r#"Hecks.bluebook "Multi" do
  aggregate "Action" do
    attribute :status, String
    command "Plan" do
      emits "Planned"
      then_set :status, to: "planned"
    end
    command "Execute" do
      reference_to(Action)
      emits "Executed"
    end
    command "Verify" do
      reference_to(Action)
      emits "Verified"
    end
    lifecycle :status, default: "draft" do
      transition "Plan" => "planned", from: "draft"
      transition "Execute" => "executed", from: "planned"
      transition "Verify" => "verified", from: "executed"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 0, "all from_states are reachable");
}

#[test]
fn warns_on_stuck_default() {
    // Lifecycle has transitions but none can fire from default.
    let source = r#"Hecks.bluebook "Stuck" do
  aggregate "Account" do
    attribute :status, String
    command "Activate" do
      reference_to(Account)
      emits "Activated"
    end
    lifecycle :status, default: "active" do
      transition "Activate" => "frozen", from: "frozen"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    // The unreachable-from check fires AND the stuck-default warning.
    let stuck = report.findings.iter()
        .any(|f| f.severity == Severity::Warning && f.message.contains("stuck"));
    assert!(stuck, "expected stuck-default warning: {:?}",
        report.findings.iter().map(|f| (&f.severity, &f.message)).collect::<Vec<_>>());
}

#[test]
fn no_warning_when_default_has_no_transitions_at_all() {
    // Lifecycle with zero transitions — degenerate but not a bug.
    let source = r#"Hecks.bluebook "Empty" do
  aggregate "Thing" do
    attribute :status, String
    command "DoIt" do
      emits "Done"
    end
    lifecycle :status, default: "active" do
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 0);
    assert_eq!(report.warnings(), 0,
        "no transitions = no stuck warning (the field just stays at default)");
}

#[test]
fn unconstrained_transition_satisfies_default() {
    // A transition with no from: clause fires from any state, including
    // default. So it counts for the stuck-default check.
    let source = r#"Hecks.bluebook "Open" do
  aggregate "Door" do
    attribute :status, String
    command "Knock" do
      reference_to(Door)
      emits "Knocked"
    end
    lifecycle :status, default: "closed" do
      transition "Knock" => "knocked"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.warnings(), 0, "no from: means fires from default too");
}
