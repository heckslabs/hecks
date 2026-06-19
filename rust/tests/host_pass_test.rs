//! Standalone effect-port HOST — end-to-end through the real `run_host_pass`.
//!
//! Boots the Shop domain with the Stripe `charged_by` effect bind and the real
//! `examples/adapter_host_demo/stripe-handler` as the adapter's handler, then
//! drives ONE host pass (the `--once` core) and asserts the full round-trip :
//! the OutboundEvent goes pending -> delivered AND the Order reaches the
//! handler's verdict (authorized by default ; declined under STRIPE_DECLINE=1).
//!
//! This exercises the SAME code path the CLI `storehouse host --once` runs —
//! claim -> exec the real bash handler out-of-process -> dispatch the verdict
//! command (threading the stdout k=v pairs + source_id) -> MarkDelivered.

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::run_host::run_host_pass;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

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

/// Absolute path to the real bash handler — `cargo test` cwd is the crate
/// (`rust/`), so a relative path would not resolve.
fn handler_path() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/../examples/adapter_host_demo/stripe-handler").to_string()
}

fn boot_shop_with_stripe() -> Runtime {
    let domain = parser::parse(SHOP);
    let adapter = format!(
        "Hecks.adapter \"Stripe\" do\n  family \"payment\"\n  handler \"{}\"\nend\n",
        handler_path()
    );
    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
        ),
        hecksagon_parser::parse(&adapter),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\") do\n    success \"Order.Authorize\"\n    failure \"Order.Decline\"\n  end\nend\n",
        ),
    ];
    Runtime::boot_in_memory_with_hecksagons(domain, hecksagons)
}

fn place_order(rt: &mut Runtime, id: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s(id));
    attrs.insert("total".to_string(), s("4200"));
    rt.dispatch("PlaceOrder", attrs).expect("PlaceOrder dispatches");
}

#[test]
fn host_pass_authorizes_order_and_delivers() {
    let mut rt = boot_shop_with_stripe();
    place_order(&mut rt, "order-1");

    // One delivery is pending before the pass.
    let before = rt.find("OutboundEvent", "Order::order-1::OrderPlaced::Stripe");
    assert_eq!(before.expect("delivery recorded").get("status"), &s("pending"));

    // The host pass : claim -> exec the real handler -> dispatch verdict -> ack.
    let acted = run_host_pass(&mut rt);
    assert_eq!(acted, 1, "one pending delivery acted on");

    // The handler demo-authorizes (no STRIPE_DECLINE) -> Order is authorized.
    let order = rt.find("Order", "order-1").expect("order exists");
    assert_eq!(
        order.get("status"),
        &s("authorized"),
        "the success verdict (Authorize) re-entered onto the originating order",
    );

    // The delivery closed : pending -> delivered.
    let delivery = rt
        .find("OutboundEvent", "Order::order-1::OrderPlaced::Stripe")
        .expect("delivery exists");
    assert_eq!(
        delivery.get("status"),
        &s("delivered"),
        "the host acked the delivery after dispatching the verdict",
    );

    // A second pass is a no-op : no delivery is pending anymore (idempotent).
    assert_eq!(run_host_pass(&mut rt), 0, "second pass acts on nothing");
}

#[test]
fn host_pass_declines_order_and_still_delivers() {
    // STRIPE_DECLINE=1 makes the handler exit non-zero -> the host dispatches
    // the failure_command (Decline). A reached verdict is HANDLED, so the
    // delivery still goes delivered (NOT failed -> pending, which would
    // re-charge the card every tick).
    //
    // The flag is delivered through the host's CONFIG-INTO-ENV path : a
    // `.world` adapter binding for Stripe carrying STRIPE_DECLINE=1, folded
    // into the handler child's env by run_host::exec. This exercises that
    // plumbing AND avoids a process-global env var that could bleed into the
    // sibling authorize test under parallel execution.
    let mut rt = boot_shop_with_stripe();
    rt.world_adapter_bindings
        .push(storehouse::world::ir::AdapterBinding {
            name: "Stripe".to_string(),
            values: vec![("STRIPE_DECLINE".to_string(), "1".to_string())],
        });
    place_order(&mut rt, "order-2");

    let acted = run_host_pass(&mut rt);
    assert_eq!(acted, 1);

    let order = rt.find("Order", "order-2").expect("order exists");
    assert_eq!(
        order.get("status"),
        &s("declined"),
        "the failure verdict (Decline) re-entered on a non-zero handler exit",
    );

    let delivery = rt
        .find("OutboundEvent", "Order::order-2::OrderPlaced::Stripe")
        .expect("delivery exists");
    assert_eq!(
        delivery.get("status"),
        &s("delivered"),
        "a reached decline verdict closes the delivery — no re-charge loop",
    );
}
