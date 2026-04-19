//! Behaviors conceiver / generator tests
//!
//! Locks the contract for `behaviors_conceiver::generator::generate_behaviors`:
//!   - Always produces a non-empty test suite.
//!   - When a same-aggregate policy cascade exists, the test for the
//!     upstream command expects the DOWNSTREAM mutated state (later wins).
//!   - Same-aggregate setup chains run in correct dependency order.
//!   - Cross-aggregate policy triggers do NOT contribute to the source
//!     command's expectations (those land in a different repo).
//!   - Cyclic policy chains terminate via the visited set.

use hecks_life::behaviors_conceiver::generator::generate_behaviors;
use hecks_life::parser;

#[test]
fn smoke_generates_non_empty_suite() {
    // Tiny domain — one aggregate, one bootstrap command. The generator
    // should emit a parseable behaviors file with a header and at least
    // one `test "..."` block.
    let source = r#"Hecks.bluebook "Tiny" do
  aggregate "Note" do
    attribute :body, String
    command "CreateNote" do
      attribute :body, String
      emits "NoteCreated"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);

    assert!(out.starts_with("Hecks.behaviors \"Tiny\" do"),
        "expected behaviors header, got:\n{}", out);
    assert!(out.contains("test \"CreateNote sets body\""),
        "expected per-command test, got:\n{}", out);
    assert!(out.contains("tests \"CreateNote\", on: \"Note\""),
        "expected `tests` declaration line, got:\n{}", out);
    assert!(out.trim_end().ends_with("end"),
        "expected suite to close with `end`, got:\n{}", out);
}

#[test]
fn cascade_through_same_aggregate_policy() {
    // The canonical cascade: AcceptParcel emits ParcelAccepted, which
    // a policy turns into SortParcel, which sets status: "sorted".
    // The test for AcceptParcel must expect status: "sorted" (the
    // post-cascade state), not "accepted" (its own then_set).
    let source = r#"Hecks.bluebook "Pipeline" do
  aggregate "Parcel" do
    attribute :status, String
    command "AcceptParcel" do
      reference_to(Parcel)
      emits "ParcelAccepted"
      then_set :status, to: "accepted"
    end
    command "SortParcel" do
      reference_to(Parcel)
      given { status == "accepted" }
      emits "ParcelSorted"
      then_set :status, to: "sorted"
    end
  end
  policy "SortOnAccept" do
    on "ParcelAccepted"
    trigger "SortParcel"
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);

    // Slice out just the AcceptParcel test so we don't confuse it with
    // SortParcel's own block (which trivially expects status: "sorted").
    let accept_block = test_block(&out, "AcceptParcel")
        .expect("AcceptParcel test block missing");

    assert!(accept_block.contains("expect"),
        "AcceptParcel block has no expect line:\n{}", accept_block);
    assert!(accept_block.contains(r#"status: "sorted""#),
        "expected cascaded status: \"sorted\" in AcceptParcel test, got:\n{}",
        accept_block);
    assert!(!accept_block.contains(r#"status: "accepted""#),
        "AcceptParcel must not stop at its own then_set; cascade should override:\n{}",
        accept_block);
}

#[test]
fn chain_planning_orders_setups_correctly() {
    // Three-step chain: Plan → Execute → Verify, each gated on the
    // previous step's status. The test for Verify must include setups
    // for Plan THEN Execute (in that order) before invoking Verify.
    let source = r#"Hecks.bluebook "Workflow" do
  aggregate "Action" do
    attribute :status, String
    command "Plan" do
      emits "Planned"
      then_set :status, to: "planned"
    end
    command "Execute" do
      reference_to(Action)
      given { status == "planned" }
      emits "Executed"
      then_set :status, to: "executed"
    end
    command "Verify" do
      reference_to(Action)
      given { status == "executed" }
      emits "Verified"
      then_set :status, to: "verified"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);

    let verify_block = test_block(&out, "Verify")
        .expect("Verify test block missing");

    let plan_pos = verify_block.find("setup  \"Plan\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"Plan\"` in Verify test, got:\n{}", verify_block));
    let exec_pos = verify_block.find("setup  \"Execute\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"Execute\"` in Verify test, got:\n{}", verify_block));

    assert!(plan_pos < exec_pos,
        "Plan setup must come before Execute setup, got:\n{}", verify_block);
}

#[test]
fn cascade_does_not_cross_aggregates() {
    // Cross-aggregate policy: AcceptOrder (on Order) emits OrderAccepted,
    // policy triggers ShipPackage (on Package). The Order aggregate's
    // expectations must NOT include Package's status mutation — that's
    // a different repo's state.
    let source = r#"Hecks.bluebook "Fulfillment" do
  aggregate "Order" do
    attribute :status, String
    command "AcceptOrder" do
      reference_to(Order)
      emits "OrderAccepted"
      then_set :status, to: "accepted"
    end
  end
  aggregate "Package" do
    attribute :status, String
    command "ShipPackage" do
      reference_to(Package)
      emits "PackageShipped"
      then_set :status, to: "shipped"
    end
  end
  policy "ShipOnAccept" do
    on "OrderAccepted"
    trigger "ShipPackage"
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);

    let accept_block = test_block(&out, "AcceptOrder")
        .expect("AcceptOrder test block missing");

    // Order's own mutation is fine.
    assert!(accept_block.contains(r#"status: "accepted""#),
        "expected own then_set status: \"accepted\":\n{}", accept_block);
    // Cross-aggregate cascade must not bleed in.
    assert!(!accept_block.contains(r#"status: "shipped""#),
        "cross-aggregate cascade must not pollute expectations:\n{}",
        accept_block);
}

#[test]
fn cyclic_policy_chain_terminates() {
    // Two commands on the same aggregate that policy-loop into each
    // other. Without the visited set, cascade_mutations would recurse
    // forever and overflow the stack. With it, the second hop stops
    // and the test still emits.
    let source = r#"Hecks.bluebook "Loop" do
  aggregate "Switch" do
    attribute :status, String
    command "TurnOn" do
      reference_to(Switch)
      emits "TurnedOn"
      then_set :status, to: "on"
    end
    command "TurnOff" do
      reference_to(Switch)
      emits "TurnedOff"
      then_set :status, to: "off"
    end
  end
  policy "OffAfterOn" do
    on "TurnedOn"
    trigger "TurnOff"
  end
  policy "OnAfterOff" do
    on "TurnedOff"
    trigger "TurnOn"
  end
end
"#;
    let domain = parser::parse(source);
    // If the cascade walker doesn't terminate, this call stack-overflows.
    let out = generate_behaviors(&domain, None);

    // Both tests must still appear.
    assert!(out.contains("test \"TurnOn"),
        "TurnOn test missing — cycle handling broke generation:\n{}", out);
    assert!(out.contains("test \"TurnOff"),
        "TurnOff test missing — cycle handling broke generation:\n{}", out);
}

// ─── helpers ────────────────────────────────────────────────────────

/// Slice the substring spanning a single `test "<cmd_name> ..."` block,
/// from the opening `  test "` line up to (but not including) the next
/// `  test "` line or end-of-string. Returns None if no test for `cmd`
/// is found.
fn test_block<'a>(out: &'a str, cmd_name: &str) -> Option<&'a str> {
    let needle = format!("  test \"{}", cmd_name);
    let start = out.find(&needle)?;
    let after = &out[start..];
    // Find the next test header AFTER this one.
    let next = after[needle.len()..].find("\n  test \"")
        .map(|n| n + needle.len())
        .unwrap_or(after.len());
    Some(&after[..next])
}
