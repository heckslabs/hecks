//! conception_kernel planner tests — lifecycle-aware Equals (slice 3a).
//!
//! A command guarded by a lifecycle `from_state` requires the aggregate to be
//! in that state; the producer is the command that TRANSITIONS to it (not a Set
//! mutation). The fixture uses pure transitions (no Set on the lifecycle field)
//! so the transition-producer path is genuinely exercised, gated against
//! generate_behaviors (the byte-oracle).
//!
//! Cascade filtering (plan_setup_chain_filtered) and the Unsatisfiable→skip
//! outcome are slice 3b — entangled with cascade-test emission, deferred.

mod common;
use common::{assert_empty_chain_but_emits, assert_matches_oracle};

const BUILDING: &str = r#"Hecks.bluebook "Building" do
  aggregate "Door" do
    attribute :state, String
    command "CreateDoor" do
      reference_to(Door)
      emits "DoorCreated"
    end
    command "Unlock" do
      reference_to(Door)
      emits "Unlocked"
    end
    command "Open" do
      reference_to(Door)
      emits "Opened"
    end
    command "Inspect" do
      reference_to(Door)
      given("must be unlocked") { state == "unlocked" }
      emits "Inspected"
    end
    lifecycle :state, default: "locked" do
      transition "Unlock" => "unlocked", from: "locked"
      transition "Open" => "opened", from: "unlocked"
    end
  end
end
"#;

#[test]
fn lifecycle_from_state_uses_transition_producer() {
    // Open transitions opened-from-unlocked, so it requires state == "unlocked";
    // the producer is Unlock (transitions to "unlocked"), not a Set.
    assert_matches_oracle(BUILDING, "Door", "Open", &["Unlock"]);
}

#[test]
fn explicit_equals_on_lifecycle_field_uses_transition_producer() {
    // An explicit `given { state == "unlocked" }` resolves through the same
    // transition producer.
    assert_matches_oracle(BUILDING, "Door", "Inspect", &["Unlock"]);
}

const WORKFLOW: &str = r#"Hecks.bluebook "Workflow" do
  aggregate "Ticket" do
    attribute :status, String
    command "CreateTicket" do
      reference_to(Ticket)
      emits "TicketCreated"
    end
    command "Reopen" do
      reference_to(Ticket)
      emits "Reopened"
    end
    command "Process" do
      reference_to(Ticket)
      emits "Processed"
    end
    lifecycle :status, default: "pending" do
      transition "Reopen" => "pending", from: "closed"
      transition "Process" => "done", from: "pending"
    end
  end
end
"#;

#[test]
fn transition_to_lifecycle_default_needs_no_setup() {
    // Process requires from_state "pending" — but "pending" IS the lifecycle
    // default, so the ticket is born there: no setup step. Reopen ALSO
    // transitions to "pending", so a default-blind planner would wrongly emit
    // `setup "Reopen"`. The agg-aware Equals default (IfDefaultMatches) closes
    // that divergence from generator's precondition_default_holds.
    assert_empty_chain_but_emits(WORKFLOW, "Ticket", "Process");
}
