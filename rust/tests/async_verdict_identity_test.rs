//! Async-boundary verdict identity — the payment verdict re-enters ON THE SAME
//! aggregate that emitted the trigger, never a phantom.
//!
//! Regression proof for BUG-async-verdict-loses-identity : the Pizzas exemplar
//! `Order.charged_by("Stripe", on: "OrderPlaced") do success "Order.Authorize"
//! failure "Order.Decline" end` binding. OrderPlaced records ONE OutboundEvent ;
//! the in-process drain (`drain_outbound_to_quiescence` — the serve/dispatch
//! boundary's synchronous wait) execs the handler and dispatches the verdict.
//! Before the fix the verdict carried NO self-reference id, so Order.Authorize
//! (a transition, upsert-on-identity) INSERTED a phantom Order#2 and stranded
//! the real Order#1 pending. The fix injects the origin source_id as the
//! verdict's `id`, so the REAL order transitions pending→authorized.
//!
//! [antibody-exempt: rust/tests/async_verdict_identity_test.rs — kernel-floor
//!  conformance test ; builds + execs a real handler script and drives the
//!  runtime drain, necessarily Rust. Sibling of effect_outbound_record_test +
//!  web_tool_oop_keystone_test.]

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

// A minimal driving domain : an Order whose PlaceOrder emits OrderPlaced, and an
// Authorize transition (upsert-on-identity) that stamps payment_ref + flips the
// status. Authorize is the verdict the Stripe success branch re-enters with.
const SHOP: &str = r#"Hecks.bluebook "Shop" do
  aggregate "Order" do
    identified_by :id
    attribute :id,          OrderId
    attribute :total,       Total
    attribute :payment_ref, PaymentRef, default: ""
    attribute :status,      Status, default: "pending"
    value_object "OrderId" do
      attribute :value, String
    end
    value_object "Total" do
      attribute :value, String
    end
    value_object "PaymentRef" do
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
      attribute :id,          OrderId
      attribute :payment_ref, PaymentRef
      then_set :payment_ref, to: :payment_ref
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

/// Write an executable shell-script handler that reports a charge id on stdout
/// and exits 0 (the success branch). Absolute path, so `resolve_handler_path`
/// takes it verbatim.
#[cfg(all(unix, not(target_arch = "wasm32")))]
fn write_success_handler() -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("async_verdict_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir handler dir");
    let path = dir.join("stripe-ok-handler.sh");
    std::fs::write(&path, "#!/bin/sh\necho \"payment_ref=ch_test_123\"\nexit 0\n")
        .expect("write handler");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod handler");
    path
}

#[cfg(all(unix, not(target_arch = "wasm32")))]
#[test]
fn verdict_transitions_the_real_order_no_phantom() {
    let handler = write_success_handler();
    let handler_str = handler.to_string_lossy().to_string();

    let domain = parser::parse(SHOP);
    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
        ),
        hecksagon_parser::parse(&format!(
            "Hecks.adapter \"Stripe\" do\n  family \"payment\"\n  handler \"{}\"\nend\n",
            handler_str
        )),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\") do\n    success \"Order.Authorize\"\n    failure \"Order.Decline\"\n  end\nend\n",
        ),
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);

    // Place TWO real orders. The verdict path's id_for_command has a singleton
    // fallback (exactly one record + no id -> that record) that would MASK the
    // bug with a single order ; the live defect surfaced precisely because many
    // orders already existed (Order #5). Two orders defeat the fallback : an
    // id-less verdict is forced to counter-mint a PHANTOM, so this test actually
    // discriminates fixed-vs-broken.
    for (id, total) in [("order-1", "4200"), ("order-2", "1500")] {
        let mut attrs = HashMap::new();
        attrs.insert("id".to_string(), s(id));
        attrs.insert("total".to_string(), s(total));
        rt.dispatch("PlaceOrder", attrs).expect("PlaceOrder dispatches");
    }

    // Exactly two OutboundEvents recorded (one per order), both pending.
    let deliveries = rt.all("OutboundEvent");
    assert_eq!(deliveries.len(), 2, "one effect binding per order records two OutboundEvents");

    // Bug B — OutboundEventRecorded fires exactly once per order (no double-record).
    let recorded = rt
        .event_bus
        .events()
        .iter()
        .filter(|e| e.name == "OutboundEventRecorded")
        .count();
    assert_eq!(recorded, 2, "OutboundEventRecorded fires exactly once per cascade (no double)");

    // Drive the in-process drain (the serve/dispatch boundary path).
    let drained = rt.drain_outbound_to_quiescence();
    assert_eq!(drained, 2, "both verdict-bearing deliveries drained");

    // THE PROOF : exactly two Orders exist — no phantom minted by either verdict.
    let orders = rt.all("Order");
    assert_eq!(orders.len(), 2, "exactly two Orders after the verdicts — no phantom");

    // … and BOTH are the real orders, each transitioned pending→authorized on its
    // OWN id, with the handler's charge id stamped in.
    for id in ["order-1", "order-2"] {
        let order = rt.find("Order", id).unwrap_or_else(|| panic!("the real {} still exists", id));
        assert_eq!(
            order.fields.get("status").map(|v| v.to_string()).as_deref(),
            Some("authorized"),
            "{} transitioned to authorized",
            id,
        );
        assert_eq!(
            order.fields.get("payment_ref").map(|v| v.to_string()).as_deref(),
            Some("ch_test_123"),
            "the charge id landed on {}",
            id,
        );
    }

    // Each verdict re-entered ON its own order : exactly two OrderAuthorized, on
    // the real ids — never a phantom aggregate id.
    let mut authorized: Vec<String> = rt
        .event_bus
        .events()
        .iter()
        .filter(|e| e.name == "OrderAuthorized")
        .map(|e| e.aggregate_id.clone())
        .collect();
    authorized.sort();
    assert_eq!(
        authorized,
        vec!["order-1".to_string(), "order-2".to_string()],
        "OrderAuthorized fired once per real order, no phantom id",
    );

    let _ = std::fs::remove_dir_all(handler.parent().unwrap());
}
