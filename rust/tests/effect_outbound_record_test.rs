//! Event-out messaging port (effect-port slice a) — the core records a durable
//! OutboundEvent when it emits an event an EFFECT binding subscribes to.
//!
//! Proves record_effect_outbound: dispatch the triggering command, and one
//! OutboundEvent lands per subscribing adapter — the durable hand-off a
//! standalone host will later consume. The host itself is a separate program ;
//! this pins only the CORE side (record on emit).

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

// A minimal driving domain : an Order whose PlaceOrder emits OrderPlaced — the
// event the effect binding hangs off.
const SHOP: &str = r#"Hecks.bluebook "Shop" do
  aggregate "Order" do
    identified_by :id
    attribute :id,     OrderId
    attribute :total,  Total
    attribute :status, Status, default: "pending"
    value_object "OrderId" do
      attribute :value, String
    end
    value_object "Total" do
      attribute :value, String
    end
    value_object "Status" do
      attribute :value, String
    end
    command "PlaceOrder" do
      role "Customer"
      attribute :id,    OrderId
      attribute :total, Total
      then_set :total, to: :total
      emits "OrderPlaced"
    end
    command "Authorize" do
      role "System"
      attribute :id, OrderId
      then_set :status, to: "authorized"
      emits "OrderAuthorized"
    end
    command "Decline" do
      role "System"
      attribute :id, OrderId
      then_set :status, to: "declined"
      emits "OrderDeclined"
    end
  end
end
"#;

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

#[test]
fn effect_binding_records_one_outbound_event_on_emit() {
    // Merge the driving domain (Order) with the framework OutboundEvent so the
    // runtime can dispatch OutboundEvent.Record.
    // No manual OutboundEvent merge : boot_with_hecksagons loads the framework
    // outbox SUBSTRATE automatically because an effect binding is present.
    let domain = parser::parse(SHOP);

    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
        ),
        hecksagon_parser::parse("Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n"),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\", into: \"Order.Authorize | Order.Decline\")\nend\n",
        ),
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("order-1"));
    attrs.insert("total".to_string(), s("4200"));
    rt.dispatch("PlaceOrder", attrs).expect("PlaceOrder dispatches");

    let deliveries = rt.all("OutboundEvent");
    assert_eq!(
        deliveries.len(),
        1,
        "one effect binding (charged_by Stripe) records exactly one OutboundEvent",
    );
    let d = deliveries[0];
    assert_eq!(d.get("adapter"), &s("Stripe"), "named for the subscribing adapter");
    assert_eq!(d.get("event"), &s("OrderPlaced"), "the triggering event");
    assert_eq!(d.get("status"), &s("pending"), "awaiting a host");
    assert_eq!(d.get("source_id"), &s("order-1"), "the originating order id");
    assert_eq!(
        d.get("success_command"),
        &s("Shop::Order.Authorize"),
        "into[0], context-qualified — the verdict the host dispatches on success",
    );
    assert_eq!(
        d.get("failure_command"),
        &s("Shop::Order.Decline"),
        "into[1] — the verdict on failure",
    );

    // The host's poll : Pending(adapter) returns the delivery for its adapter.
    let mut q = HashMap::new();
    q.insert("adapter".to_string(), "Stripe".to_string());
    let pending = rt.resolve_query("Pending", &q);
    let state = &pending["state"];
    assert_eq!(
        state["adapter"].as_str(),
        Some("Stripe"),
        "Pending(adapter: Stripe) returns the Stripe delivery",
    );
    assert_eq!(state["status"].as_str(), Some("pending"));
    assert_eq!(state["success_command"].as_str(), Some("Shop::Order.Authorize"));

    // A non-subscribing adapter sees nothing — the host only consumes its own.
    let mut q2 = HashMap::new();
    q2.insert("adapter".to_string(), "Ghost".to_string());
    let none = rt.resolve_query("Pending", &q2);
    assert!(
        none["state"].as_str().is_none()
            && none["state"].as_object().is_none(),
        "Pending(adapter: Ghost) returns no delivery (got {:?})",
        none["state"],
    );
}

#[test]
fn reply_binding_records_no_outbound_event() {
    // persisted_by is a reply port (DI, in-process) — no event-out, no delivery.
    // No manual OutboundEvent merge : boot_with_hecksagons loads the framework
    // outbox SUBSTRATE automatically because an effect binding is present.
    let domain = parser::parse(SHOP);

    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"persistence\" do\n  verb \"persisted_by\"\n  signal :reply\n  field :dir\nend\n",
        ),
        hecksagon_parser::parse("Hecks.adapter \"Heki\" do\n  family \"persistence\"\nend\n"),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.persisted_by(\"Heki\")\nend\n",
        ),
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("order-2"));
    attrs.insert("total".to_string(), s("100"));
    rt.dispatch("PlaceOrder", attrs).expect("PlaceOrder dispatches");

    assert!(
        rt.all("OutboundEvent").is_empty(),
        "a reply port is DI/in-process — it records no outbound delivery",
    );
}

#[test]
fn host_round_trip_consumes_claims_dispatches_verdict_and_acks() {
    // The FULL effect-port round-trip, end to end, through the SAME public door a
    // standalone host speaks (resolve_query + dispatch) — no host code in the
    // crate, so nothing re-couples : this test simulates the out-of-process host.
    // No manual OutboundEvent merge : boot_with_hecksagons loads the framework
    // outbox SUBSTRATE automatically because an effect binding is present.
    let domain = parser::parse(SHOP);
    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
        ),
        hecksagon_parser::parse("Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n"),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\", into: \"Order.Authorize | Order.Decline\")\nend\n",
        ),
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);

    // 1. Driving command — the core emits OrderPlaced and records the delivery.
    let mut place = HashMap::new();
    place.insert("id".to_string(), s("order-7"));
    place.insert("total".to_string(), s("999"));
    rt.dispatch("PlaceOrder", place).expect("PlaceOrder");

    // 2. HOST: poll its pending deliveries.
    let mut q = HashMap::new();
    q.insert("adapter".to_string(), "Stripe".to_string());
    let pending = rt.resolve_query("Pending", &q);
    let d = &pending["state"];
    let delivery_id = d["delivery_id"].as_str().expect("delivery_id").to_string();
    let source_id = d["source_id"].as_str().expect("source_id").to_string();
    let success_command = d["success_command"].as_str().expect("success_command").to_string();
    // The host re-enters with the verdict command the delivery named.
    let verdict_bare = success_command.rsplit('.').next().unwrap().to_string();

    // 3. HOST: claim -> (thin handler returns success) -> dispatch verdict -> ack.
    let mut claim = HashMap::new();
    claim.insert("delivery_id".to_string(), s(&delivery_id));
    rt.dispatch("Claim", claim).expect("Claim");

    let mut verdict = HashMap::new();
    verdict.insert("id".to_string(), s(&source_id));
    rt.dispatch(&verdict_bare, verdict).expect("verdict dispatch");

    let mut ack = HashMap::new();
    ack.insert("delivery_id".to_string(), s(&delivery_id));
    rt.dispatch("MarkDelivered", ack).expect("MarkDelivered");

    // The verdict landed on the originating order, and the delivery closed.
    let order = rt.find("Order", "order-7").expect("order exists");
    assert_eq!(
        order.get("status"),
        &s("authorized"),
        "the host's success verdict (Authorize) re-entered onto the right order",
    );
    let closed = rt.find("OutboundEvent", &delivery_id).expect("delivery exists");
    assert_eq!(
        closed.get("status"),
        &s("delivered"),
        "the host acked the delivery after dispatching the verdict",
    );
}
