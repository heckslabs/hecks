//! STEP ZERO for CARD-framework-substrate-service : the kernel writes the event
//! Log through an injected FRAMEWORK COLLABORATOR, not by requiring the
//! EventSourcing chapter to have been merged into the user's domain.
//!
//! The bug this closes : `record_event_append` used to open with
//!
//!     if !self.repositories.contains_key(&es_key) { return; }
//!
//! "no Log unless EventSourcing is in MY domain". So a domain that explicitly
//! declared `event_sourced` in its hecksagon, and did everything right, still
//! silently wrote nothing if it was booted from a single bluebook. Silently is
//! the operative word — no error, no warning, just no Log. This test is that
//! exact configuration : ONE bluebook, no corpus, no EventSourcing chapter
//! anywhere in the domain.
//!
//! It also pins the two structural properties the collaborator depends on :
//! the user's domain stays clean (nothing is grafted into it), and the
//! recursion is bounded (the collaborator has no collaborator of its own).

use std::collections::HashMap;
use storehouse::runtime::{Runtime, Value};
use storehouse::{hecksagon_parser, parser};

/// One bluebook. No EventSourcing chapter, no corpus, no framework dir.
const LEDGER: &str = r#"Hecks.bluebook "Ledger" do
  aggregate "Entry" do
    identified_by :entry_id
    attribute :entry_id, EntryId
    attribute :memo,     Memo
    value_object "EntryId" do
      attribute :value, String
    end
    value_object "Memo" do
      attribute :value, String
    end
    command "Post" do
      role "System"
      attribute :entry_id, EntryId
      attribute :memo,     Memo
      then_set :memo, to: :memo
      emits "Posted"
    end
  end
end
"#;

/// The whole wiring : persistence plus the persistence+ event-sourcing toggle.
const LEDGER_HEX: &str = r#"Hecks.hecksagon "Ledger" do
  Ledger::Entry.persisted_by("Heki")
  Ledger::Entry.event_sourced
end
"#;

fn boot(dir: &std::path::Path) -> Runtime {
    Runtime::boot_with_hecksagons(
        parser::parse(LEDGER),
        Some(dir.to_string_lossy().into_owned()),
        vec![hecksagon_parser::parse(LEDGER_HEX)],
    )
}

fn post(rt: &mut Runtime, id: &str, memo: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("entry_id".to_string(), Value::Str(id.to_string()));
    attrs.insert("memo".to_string(), Value::Str(memo.to_string()));
    rt.dispatch("Ledger::Entry.Post", attrs).expect("Post dispatches");
}

#[test]
fn a_single_bluebook_boot_writes_the_log_through_the_collaborator() {
    let dir = std::env::temp_dir().join("fw_collab_step_zero");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = boot(&dir);

    // Precondition : the EventSourcing chapter is NOT in this domain. If this
    // ever fails, something grafted it in and the test below proves nothing.
    assert!(
        !rt.domain.aggregates.iter().any(|a| a.name == "Event"),
        "the user's domain must NOT contain EventSourcing::Event — that is the \
         whole point (aggregates: {:?})",
        rt.domain.aggregates.iter().map(|a| &a.name).collect::<Vec<_>>(),
    );

    post(&mut rt, "e-1", "first");

    // The Log lives in the collaborator.
    let fw = rt.framework.as_ref().expect("the collaborator booted on first append");
    let events = fw.all_qualified(Some("EventSourcing"), "Event");
    assert!(
        !events.is_empty(),
        "a single-bluebook boot carrying `event_sourced` must write its deltas \
         to the Log — this is the case that silently wrote NOTHING before the \
         collaborator existed",
    );
    assert!(
        events.iter().any(|e| e.get("aggregate_name").to_string().contains("Entry")),
        "the recorded events belong to the user's aggregate (got {:?})",
        events.iter().map(|e| e.get("aggregate_name").to_string()).collect::<Vec<_>>(),
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_users_domain_stays_clean_and_the_recursion_is_bounded() {
    let dir = std::env::temp_dir().join("fw_collab_bounds");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = boot(&dir);
    post(&mut rt, "e-1", "first");

    // 1. Nothing was grafted. The served surface renders the domain, so this is
    //    what keeps framework substrate off a user's page — by construction,
    //    with no filter to maintain.
    let names: Vec<String> = rt.domain.aggregates.iter().map(|a| a.name.clone()).collect();
    assert_eq!(
        names,
        vec!["Entry".to_string()],
        "the user's domain is exactly what its author wrote",
    );

    // 2. The recursion terminates : the collaborator has no collaborator. If it
    //    ever booted one, every Append would boot another runtime and the
    //    process would spiral.
    let fw = rt.framework.as_ref().expect("collaborator booted");
    assert!(
        fw.framework.is_none(),
        "the collaborator must not boot a collaborator of its own — that is what \
         bounds the recursion",
    );

    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// THE OUTBOX — and the symptom that opened this whole arc.
//
// ToolShed's served page rendered the framework OutboundEvent as one of its own
// modules. The cause was `ensure_outbox_substrate`, which SPLICED the outbox
// aggregate into any domain with an effect binding so the kernel's
// "is OutboundEvent in MY domain?" guards would pass. It was narrowed once
// (scoped to a domain's OWN effect port) and then deleted outright, because a
// domain never needed to carry the outbox — only to reach it.
//
// Now a served page shows exactly what its author wrote, by construction. There
// is no graft to scope and no UI filter to maintain.
// ---------------------------------------------------------------------------

const SHOP: &str = r#"Hecks.bluebook "Shop" do
  aggregate "Order" do
    identified_by :id
    attribute :id,     OrderId
    attribute :status, Status, default: "pending"
    value_object "OrderId" do
      attribute :value, String
    end
    value_object "Status" do
      attribute :value, String
    end
    command "PlaceOrder" do
      role "Customer"
      attribute :id, OrderId
      emits "OrderPlaced"
    end
    command "Authorize" do
      role "System"
      attribute :id, OrderId
      then_set :status, to: "authorized"
    end
    command "Decline" do
      role "System"
      attribute :id, OrderId
      then_set :status, to: "declined"
    end
  end
end
"#;

fn shop_with_effect_port() -> Runtime {
    Runtime::boot_with_hecksagons(
        parser::parse(SHOP),
        None,
        vec![
            hecksagon_parser::parse(
                "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
            ),
            hecksagon_parser::parse("Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n"),
            hecksagon_parser::parse(
                "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\") do\n    success \"Order.Authorize\"\n    failure \"Order.Decline\"\n  end\nend\n",
            ),
        ],
    )
}

#[test]
fn a_domain_with_an_effect_port_never_carries_the_outbox() {
    let mut rt = shop_with_effect_port();

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), Value::Str("order-1".to_string()));
    rt.dispatch("PlaceOrder", attrs).expect("PlaceOrder dispatches");

    // The delivery WAS recorded — the effect port works.
    assert_eq!(
        rt.outbound_deliveries().len(),
        1,
        "the effect binding records its delivery into the collaborator",
    );

    // ...and the served domain is exactly what its author wrote. This is the
    // ToolShed symptom, now unrepresentable rather than merely fixed.
    let names: Vec<String> = rt.domain.aggregates.iter().map(|a| a.name.clone()).collect();
    assert_eq!(
        names,
        vec!["Order".to_string()],
        "a domain declaring an effect port must NOT acquire OutboundEvent as one \
         of its own aggregates — it reaches the outbox by calling, not by \
         carrying (got {:?})",
        names,
    );
}

// ---------------------------------------------------------------------------
// THE DOOR — the half that the unit suite could not see.
//
// Every IN-process caller was rerouted to the collaborator and no OUT-of-process
// door was, so 124/124 unit binaries stayed green while `dream_content_smoke`
// failed : the CLI resolves a verb against the SERVED domain, framework
// substrate is deliberately not in it, and the verb died as an unknown command
// with `2>/dev/null` swallowing the error.
//
// `framework_resolves` is the door-side lookup. These pin BOTH halves of its
// contract — it must find substrate the served domain lacks, and it must not
// override a domain that declares its own.
// ---------------------------------------------------------------------------

#[test]
fn the_door_resolves_framework_substrate_the_served_domain_lacks() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(LEDGER), None, vec![]);

    assert!(
        !rt.domain.aggregates.iter().any(|a| a.name == "OutboundEvent"),
        "precondition : the served domain must NOT carry the outbox",
    );

    assert!(
        rt.framework_resolves("OutboundEvent", "pending"),
        "the door must reach the outbox's Pending query through the collaborator — \
         this is the lookup whose absence broke dream_content_smoke",
    );
    assert!(
        rt.framework_resolves("OutboundEvent", "Claim"),
        "and its lifecycle COMMANDS too — the adapter host dispatches Claim / \
         MarkDelivered from a separate process",
    );
    assert!(
        rt.framework_resolves("Event", "Append"),
        "the same door serves every substrate, not just the outbox",
    );
    assert!(
        !rt.framework_resolves("Entry", "Post"),
        "a USER aggregate must not resolve through the framework door",
    );
    assert!(
        !rt.framework_resolves("OutboundEvent", "NoSuchVerb"),
        "an unknown verb on a real substrate aggregate still does not resolve",
    );
}

#[test]
fn a_domain_declaring_its_own_outbox_is_not_overridden() {
    // PRECEDENCE. The door consults the collaborator only AFTER the served
    // domain fails, so a domain that declares its own OutboundEvent keeps it.
    // This replaces outbox_graft_scope_test, which pinned the deleted graft's
    // predicate : the question it asked (whose outbox wins?) is still live, the
    // mechanism it asked about is not.
    const OWN: &str = r#"Hecks.bluebook "Shipping" do
      aggregate "OutboundEvent" do
        identified_by :delivery_id
        attribute :delivery_id, DeliveryId
        value_object "DeliveryId" do
          attribute :value, String
        end
        query "Pending" do
          where status: "pending"
        end
      end
    end
    "#;
    let rt = Runtime::boot_with_hecksagons(parser::parse(OWN), None, vec![]);

    // The served domain resolves it itself, so the door never falls through.
    let own = rt.domain.aggregates.iter().find(|a| a.name == "OutboundEvent");
    assert!(own.is_some(), "the domain's own OutboundEvent survives");
    assert!(
        own.unwrap().queries.iter().any(|q| q.name == "Pending"),
        "and it is the DOMAIN's Pending that answers, not the framework's",
    );
}

// ---------------------------------------------------------------------------
// GOVERNANCE — the same coupling, with the worst consequence.
//
// `record_violation_internal` used to be `let _ = self.dispatch_impl(...)`, so
// on a runtime that had not merged the Governance conception the dispatch
// failed and the Result was DISCARDED : a denied dispatch left no audit row and
// no trace of the loss. The denial always stood — this was never an
// authorization hole — but "who was refused what, and why" is the whole point
// of a veto audit, and it was contingent on corpus layout.
//
// The setup below is lifted from `authorize_pdp_test`, which boots exactly such
// a runtime : storehouse + authorization + a demo domain, and NO Governance.
// Every denial that file asserts recorded nothing at all.
// ---------------------------------------------------------------------------

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

fn s(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}

/// storehouse + authorization + demo domain. Deliberately NO Governance chapter.
fn gated_runtime() -> Runtime {
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    // Turn the PDP gate on as System (admitted by origin), so deny-by-default
    // is in force for an agent dispatch.
    rt.dispatch(
        "Declare",
        s(&[
            ("name", "authorize"),
            ("phase", "before"),
            ("check", "authorize"),
            ("pattern", "*"),
            ("order", "30"),
        ]),
    )
    .expect("Declare authorize gate");
    rt
}

#[test]
fn a_denied_dispatch_records_its_violation_through_the_collaborator() {
    let mut rt = gated_runtime();

    // Precondition : Governance is NOT in this domain. If it ever is, this test
    // proves nothing about the collaborator.
    assert!(
        !rt.domain.aggregates.iter().any(|a| a.name == "Violation"),
        "the gated runtime must NOT carry Governance::Violation — that is the case \
         whose audit row used to vanish",
    );

    // Deny-by-default : an agent with no permit.
    let mut attrs = s(&[("name", "v1")]);
    attrs.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    attrs.insert("actor_auth_id".to_string(), Value::Str("alice".to_string()));
    let denied = rt.dispatch("Open", attrs);
    assert!(denied.is_err(), "deny-by-default must refuse an unpermitted agent");

    // The audit row exists, in the collaborator.
    let fw = rt.framework.as_ref().expect("the collaborator booted to record the denial");
    let violations = fw.all_qualified(Some("Governance"), "Violation");
    assert_eq!(
        violations.len(),
        1,
        "a denied dispatch must leave exactly one audit row (got {})",
        violations.len(),
    );
    let v = violations[0];
    assert_eq!(
        v.get("tool_name").to_string(),
        "Open",
        "the row names the refused command",
    );
    assert_eq!(v.get("gate").to_string(), "authorize", "and which gate refused it");
    assert!(
        !v.get("cause").to_string().is_empty(),
        "and why — the structured cause is what makes the row auditable rather \
         than merely present",
    );
}

#[test]
fn an_allowed_dispatch_records_no_violation() {
    // The collaborator makes the audit sink REACHABLE ; it must not make it
    // chatty. A permitted dispatch leaves no row.
    let mut rt = gated_runtime();
    rt.dispatch(
        "Permit",
        s(&[
            ("id", "p1"),
            ("principal", "alice"),
            ("action", "Open"),
            ("resource", "*"),
            ("condition", "-"),
            ("expires_at", "-"),
        ]),
    )
    .expect("Permit");

    let mut attrs = s(&[("name", "v1")]);
    attrs.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    attrs.insert("actor_auth_id".to_string(), Value::Str("alice".to_string()));
    rt.dispatch("Open", attrs).expect("a permitted agent is admitted");

    let recorded = rt
        .framework
        .as_ref()
        .map(|fw| fw.all_qualified(Some("Governance"), "Violation").len())
        .unwrap_or(0);
    assert_eq!(recorded, 0, "an allowed dispatch is not a violation");
}

#[test]
fn no_directive_means_no_log_even_with_the_collaborator_available() {
    // The collaborator makes the Log REACHABLE ; it must not make it automatic.
    // Without `event_sourced` (and without the global env override) a domain
    // still writes nothing — otherwise every runtime in the corpus would start
    // event-sourcing itself by surprise.
    let dir = std::env::temp_dir().join("fw_collab_no_directive");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = Runtime::boot_with_hecksagons(
        parser::parse(LEDGER),
        Some(dir.to_string_lossy().into_owned()),
        vec![hecksagon_parser::parse(
            "Hecks.hecksagon \"Ledger\" do\n  Ledger::Entry.persisted_by(\"Heki\")\nend\n",
        )],
    );
    post(&mut rt, "e-1", "first");

    let logged = rt
        .framework
        .as_ref()
        .map(|fw| fw.all_qualified(Some("EventSourcing"), "Event").len())
        .unwrap_or(0);
    assert_eq!(
        logged, 0,
        "no `event_sourced` directive means no Log — reachability is not consent",
    );

    let _ = std::fs::remove_dir_all(&dir);
}
