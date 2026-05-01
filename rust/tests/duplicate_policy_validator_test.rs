//! Duplicate policy validator tests
//!
//! Locks the contract: two policies sharing `(on_event, trigger_command)`
//! cause the same command to fire twice per event — that's a cascade bug.
//! The validator must flag them at check time, before the runtime quietly
//! doubles up.

use hecks_life::duplicate_policy_validator::check;
use hecks_life::parser;
use std::process::Command;

#[test]
fn flags_two_policies_sharing_event_and_trigger() {
    let source = r#"Hecks.bluebook "Dup" do
  aggregate "Heart" do
    attribute :beats, Integer
    command "Beat" do
      emits "HeartBeat"
    end
    command "Tick" do
      reference_to(Heart)
      emits "Ticked"
    end
  end
  policy "TickOnBeat" do
    on "HeartBeat"
    trigger "Tick"
  end
  policy "TickOnBeatAgain" do
    on "HeartBeat"
    trigger "Tick"
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 1, "expected one duplicate-policy error");
    let msg = &report.findings[0].message;
    assert!(msg.contains("HeartBeat"), "message should name the event: {:?}", msg);
    assert!(msg.contains("Tick"),      "message should name the trigger: {:?}", msg);
    let loc = &report.findings[0].location;
    assert!(loc.contains("TickOnBeat") && loc.contains("TickOnBeatAgain"),
        "location should list both policy names: {:?}", loc);
}

#[test]
fn passes_when_policies_are_unique() {
    let source = r#"Hecks.bluebook "Clean" do
  aggregate "Order" do
    attribute :status, String
    command "PlaceOrder" do
      emits "OrderPlaced"
    end
    command "NotifyKitchen" do
      reference_to(Order)
      emits "KitchenNotified"
    end
    command "ChargeCard" do
      reference_to(Order)
      emits "CardCharged"
    end
  end
  policy "KitchenOnPlaced" do
    on "OrderPlaced"
    trigger "NotifyKitchen"
  end
  policy "ChargeOnPlaced" do
    on "OrderPlaced"
    trigger "ChargeCard"
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 0,
        "distinct (event, trigger) pairs should pass: {:?}",
        report.findings.iter().map(|f| &f.message).collect::<Vec<_>>());
    assert!(report.passes());
}

#[test]
fn flags_three_way_duplicate_with_count_in_message() {
    // Edge case: three+ policies on the same pair. Message should
    // reflect the actual count, not hardcode "2".
    let source = r#"Hecks.bluebook "Triple" do
  aggregate "Bell" do
    attribute :name, String
    command "Ring" do
      emits "Rang"
    end
    command "Echo" do
      reference_to(Bell)
      emits "Echoed"
    end
  end
  policy "EchoA" do
    on "Rang"
    trigger "Echo"
  end
  policy "EchoB" do
    on "Rang"
    trigger "Echo"
  end
  policy "EchoC" do
    on "Rang"
    trigger "Echo"
  end
end
"#;
    let domain = parser::parse(source);
    let report = check(&domain);
    assert_eq!(report.errors(), 1);
    let msg = &report.findings[0].message;
    assert!(msg.contains("3 policies") || msg.contains("3 times"),
        "message should reflect count of 3: {:?}", msg);
}

// ─── Subcommand integration test ───────────────────────────────────
//
// Boots the built hecks-life binary against the negative fixture and
// confirms exit code 1 plus a clear "duplicate" listing on stdout.
// Uses CARGO_BIN_EXE_hecks-life — Cargo sets this when running
// `cargo test` for integration tests.

#[test]
fn subcommand_exits_nonzero_on_duplicate_fixture() {
    let bin = env!("CARGO_BIN_EXE_hecks-life");
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"),
                          "/tests/fixtures/duplicate_policy.bluebook");

    let output = Command::new(bin)
        .arg("check-duplicate-policies")
        .arg(fixture)
        .output()
        .expect("failed to invoke hecks-life");

    assert!(!output.status.success(),
        "expected non-zero exit on duplicate fixture; stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr));

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Duplicate policies"),
        "stdout should list duplicates: {}", stdout);
    assert!(stdout.contains("HeartBeat") && stdout.contains("Tick"),
        "stdout should name the (event, trigger) pair: {}", stdout);
}
