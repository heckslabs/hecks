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
fn cascade_locked_down_via_emits() {
    // The canonical cascade: AcceptParcel emits ParcelAccepted, which
    // a policy turns into SortParcel, which emits ParcelSorted. The test
    // for AcceptParcel asserts the cascade as a list of events via
    // `emits: [...]` — VCR for the emit→policy→trigger graph. Direct
    // mutations (status: "accepted") still appear; cascade mutations
    // (status: "sorted") do NOT — those belong to SortParcel's own test.
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

    // Three structural assertions — each general (works for any
    // bluebook), they just happen to use names from THIS fixture as
    // the concrete handles.

    // 1. Every command emits a state test asserting its own direct
    //    mutations only (no emits, no cascade-state).
    for cmd in &["AcceptParcel", "SortParcel"] {
        let block = test_block(&out, cmd)
            .unwrap_or_else(|| panic!("missing state test for {}", cmd));
        assert!(!block.contains("emits:"),
            "{} state test must NOT contain emits — that lives in the \
             separate cascade test:\n{}", cmd, block);
    }

    // 2. AcceptParcel mutates status to "accepted" (its own then_set).
    //    Generator should surface that as a state expectation.
    let accept = test_block(&out, "AcceptParcel").unwrap();
    assert!(accept.contains(r#"status: "accepted""#),
        "expected direct then_set surfaced in state test:\n{}", accept);

    // 3. Commands whose emit cascades through ≥1 policy get a
    //    dedicated `kind: :cascade` test asserting the emit list.
    //    Source declares: AcceptParcel → ParcelAccepted → SortParcel
    //    → ParcelSorted (a 2-event chain).
    let cascade_blocks: Vec<&str> = out.split("test \"")
        .filter(|b| b.contains("kind: :cascade"))
        .collect();
    assert_eq!(cascade_blocks.len(), 1,
        "expected exactly one cascade test (for AcceptParcel); got {}:\n{}",
        cascade_blocks.len(), out);
    let cascade = cascade_blocks[0];
    assert!(cascade.contains(r#"tests "AcceptParcel""#),
        "cascade test should target the chain's head command:\n{}", cascade);
    assert!(cascade.contains(r#"emits: ["ParcelAccepted", "ParcelSorted"]"#),
        "cascade test should lock down the static emit chain:\n{}", cascade);
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

#[test]
fn skips_command_with_truly_opaque_given() {
    // Commands whose preconditions are opaque English prose can't be
    // satisfied by the chain planner — there's no field/op to reason
    // about. The test should be skipped (the previous round handled
    // this case via the non-equality skip; this case still applies
    // even after the planner extension).
    let source = r#"Hecks.bluebook "Inventory" do
  aggregate "Stock" do
    attribute :quantity, Integer
    command "AddStock" do
      attribute :quantity, Integer
      emits "StockAdded"
      then_set :quantity, to: :quantity
    end
    command "OpaqueOp" do
      reference_to(Stock)
      given "supplier must be in good standing"
      emits "OpaqueRan"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);

    // The bootstrap command (no givens) still gets a test.
    assert!(out.contains("test \"AddStock"),
        "AddStock test (no givens) should still emit:\n{}", out);
    // The opaque-given command must NOT have an isolated test.
    assert!(!out.contains("test \"OpaqueOp"),
        "OpaqueOp has an opaque given — must be skipped, got:\n{}",
        out);
    assert!(!out.contains("tests \"OpaqueOp\""),
        "OpaqueOp tests-line must be skipped, got:\n{}", out);
}

#[test]
fn satisfies_inequality_given_with_increment_or_set() {
    // `given { quantity_used > 0 }` is now planner-reasonable: the
    // planner finds a Set producer that lands quantity_used at >= 1
    // (the bootstrap `AddStock` sets it via the input attribute). The
    // test should emit and pass.
    let source = r#"Hecks.bluebook "Inventory" do
  aggregate "Stock" do
    attribute :quantity, Integer
    command "AddStock" do
      attribute :quantity, Integer
      emits "StockAdded"
      then_set :quantity, to: :quantity
    end
    command "ConsumeStock" do
      reference_to(Stock)
      attribute :quantity_used, Integer
      given("must have stock") { quantity_used > 0 }
      emits "StockConsumed"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    assert!(out.contains("test \"ConsumeStock"),
        "ConsumeStock test should emit now that planner handles `> 0`:\n{}", out);
    // It should setup AddStock first (the producer for quantity).
    let block = test_block(&out, "ConsumeStock").expect("ConsumeStock block");
    assert!(block.contains("setup  \"AddStock\""),
        "expected AddStock setup before ConsumeStock test, got:\n{}", block);
}

#[test]
fn satisfies_boolean_equality_given() {
    // `given { ready == true }` is parseable as an equality. The planner
    // finds a producer that does `then_set :ready, to: true` and runs
    // it as setup. Test should emit and pass.
    let source = r#"Hecks.bluebook "Switch" do
  aggregate "Device" do
    attribute :ready, Boolean
    command "Initialize" do
      reference_to(Device)
      emits "Initialized"
      then_set :ready, to: true
    end
    command "Activate" do
      reference_to(Device)
      given("device must be ready") { ready == true }
      emits "Activated"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    let block = test_block(&out, "Activate").expect("Activate test block");
    assert!(block.contains("setup  \"Initialize\""),
        "expected Initialize setup (ready=true producer) before Activate, got:\n{}", block);
}

#[test]
fn satisfies_size_check_given_via_append() {
    // `given { items.size > 0 }` is parseable as NonEmptyList. The
    // planner finds an Append producer (`AddItem`) and runs it once.
    let source = r#"Hecks.bluebook "Cart" do
  aggregate "Cart" do
    attribute :items, String, list: true
    command "OpenCart" do
      emits "CartOpened"
    end
    command "AddItem" do
      reference_to(Cart)
      attribute :name, String
      emits "ItemAdded"
      then_set :items, append: :name
    end
    command "Checkout" do
      reference_to(Cart)
      given("cart must have items") { items.size > 0 }
      emits "CheckedOut"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    let block = test_block(&out, "Checkout").expect("Checkout test block");
    assert!(block.contains("setup  \"AddItem\""),
        "expected AddItem (append producer) setup before Checkout, got:\n{}", block);
}

#[test]
fn empty_list_given_satisfied_by_default() {
    // `given { items.empty? }` is true by default (lists start empty).
    // No setup chain step needed beyond the bootstrap create.
    let source = r#"Hecks.bluebook "Cart" do
  aggregate "Cart" do
    attribute :items, String, list: true
    command "OpenCart" do
      emits "CartOpened"
    end
    command "Reset" do
      reference_to(Cart)
      given("cart must be empty") { items.empty? }
      emits "Reset"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    assert!(out.contains("test \"Reset"),
        "Reset should emit (precondition trivially satisfied):\n{}", out);
}

#[test]
fn bootstrap_fallback_recurses_on_its_own_preconditions() {
    // Aggregate has no Create-style command; the chain planner falls back
    // to a non-self-ref command (`Trace`) as bootstrap. That bootstrap
    // itself has a `given` precondition, satisfied by `Confirm`. Without
    // the fix, the test for `Detect` would set up `Trace` directly and
    // fail at runtime; with the fix, `Confirm` is planned + emitted first.
    let source = r#"Hecks.bluebook "CC" do
  aggregate "Analysis" do
    attribute :ready, Boolean, default: false
    command "Confirm" do
      reference_to(Analysis)
      emits "Confirmed"
      then_set :ready, to: true
    end
    command "Trace" do
      attribute :event, String
      given { ready == true }
      emits "Traced"
    end
    command "Detect" do
      reference_to(Analysis)
      emits "Detected"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    let block = test_block(&out, "Detect").expect("Detect test block missing");
    // The bootstrap fallback (Trace) needs Confirm to run first.
    let confirm_pos = block.find("setup  \"Confirm\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"Confirm\"` (Trace's precondition producer) in Detect test, got:\n{}",
            block));
    let trace_pos = block.find("setup  \"Trace\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"Trace\"` (bootstrap fallback) in Detect test, got:\n{}",
            block));
    assert!(confirm_pos < trace_pos,
        "Confirm setup must come before Trace setup, got:\n{}", block);
}

#[test]
fn cross_ref_create_recurses_on_its_own_preconditions() {
    // Cross-aggregate dep: `Analyze` (on Report) cross-refs the `Source`
    // aggregate. Source's only bootstrap is `OpenSource`, which itself
    // has a precondition (`primed == true`) satisfied by `PrimeSource`.
    // Without the fix, the cross-ref create path inserts `OpenSource`
    // bare and the runtime errors on the given. With the fix, the
    // PrimeSource setup is planned + emitted first, in the target
    // aggregate's context.
    let source = r#"Hecks.bluebook "Cross" do
  aggregate "Source" do
    attribute :primed, Boolean, default: false
    command "PrimeSource" do
      reference_to(Source)
      emits "SourcePrimed"
      then_set :primed, to: true
    end
    command "OpenSource" do
      given { primed == true }
      emits "SourceOpened"
    end
  end
  aggregate "Report" do
    attribute :note, String
    command "Analyze" do
      reference_to(Source)
      attribute :note, String
      emits "Analyzed"
    end
  end
end
"#;
    let domain = parser::parse(source);
    let out = generate_behaviors(&domain, None);
    let block = test_block(&out, "Analyze").expect("Analyze test block missing");
    let prime_pos = block.find("setup  \"PrimeSource\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"PrimeSource\"` (cross-ref create's precondition producer) in Analyze test, got:\n{}",
            block));
    let open_pos = block.find("setup  \"OpenSource\"")
        .unwrap_or_else(|| panic!(
            "expected `setup  \"OpenSource\"` (cross-ref create) in Analyze test, got:\n{}",
            block));
    assert!(prime_pos < open_pos,
        "PrimeSource setup must come before OpenSource setup, got:\n{}", block);
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
