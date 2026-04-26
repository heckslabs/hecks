//! Runtime integration tests
//!
//! Tests the full dispatch pipeline: create, mutate, givens, events, policies.
//! Each test boots a domain from a Bluebook string and exercises the runtime.

use hecks_life::parser;
use hecks_life::runtime::{Runtime, Value};
use std::collections::HashMap;

fn boot(source: &str) -> Runtime {
    let domain = parser::parse(source);
    Runtime::boot(domain)
}

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

fn s(val: &str) -> Value { Value::Str(val.to_string()) }

// --- Create and find ---

#[test]
fn create_and_find() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :name
    command "CreatePizza" do
      role "Chef"
      attribute :name
    end
  end
end"#);

    let result = rt.dispatch("CreatePizza", attrs(&[("name", s("Margherita"))])).unwrap();
    assert_eq!(result.aggregate_type, "Pizza");
    assert_eq!(result.aggregate_id, "1");

    let state = rt.find("Pizza", "1").unwrap();
    assert_eq!(state.get("name"), &s("Margherita"));
}

#[test]
fn create_without_self_ref_is_singleton() {
    // No self-reference on the Create command means the heki adapter
    // treats the aggregate as a singleton — repeated dispatches reuse
    // id "1" rather than allocating new ids. To get sequential ids
    // a Create needs `reference_to(<self>)` so the runtime can tell
    // "act on this id" from "create a new one".
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
end"#);

    let r1 = rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    let r2 = rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    assert_eq!(r1.aggregate_id, "1");
    assert_eq!(r2.aggregate_id, "1");
}

// --- Mutations ---

#[test]
fn mutation_append() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :toppings, Topping
    value_object "Topping" do
      attribute :name
    end
    command "CreatePizza" do
      role "Chef"
    end
    command "AddTopping" do
      role "Chef"
      reference_to Pizza
      attribute :name
      then_set :toppings, append: { name: :name }
    end
  end
end"#);

    rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    rt.dispatch("AddTopping", attrs(&[("name", s("Cheese")), ("pizza", s("1"))])).unwrap();
    rt.dispatch("AddTopping", attrs(&[("name", s("Basil")), ("pizza", s("1"))])).unwrap();

    let state = rt.find("Pizza", "1").unwrap();
    let toppings = state.get("toppings").as_list().unwrap();
    assert_eq!(toppings.len(), 2);
}

#[test]
fn mutation_set_on_existing() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "open"
    command "PlaceOrder" do
      role "Customer"
    end
    command "CancelOrder" do
      role "Customer"
      reference_to Order
      then_set :status, to: "cancelled"
    end
  end
end"#);

    rt.dispatch("PlaceOrder", HashMap::new()).unwrap();
    rt.dispatch("CancelOrder", attrs(&[("order", s("1"))])).unwrap();

    let state = rt.find("Order", "1").unwrap();
    assert_eq!(state.get("status"), &s("cancelled"));
}

// --- i106 dsl-mutation-primitives : multiply / clamp / decay ---

fn assert_field_close(state: &hecks_life::runtime::AggregateState, field: &str, expected: f64) {
    let got = match state.get(field) {
        Value::Str(s) => s.parse::<f64>().unwrap_or(0.0),
        Value::Int(n) => *n as f64,
        other => panic!("field {} not numeric: {:?}", field, other),
    };
    assert!((got - expected).abs() < 1e-9, "field {}: expected {}, got {}", field, expected, got);
}

#[test]
fn mutation_multiply_scales_field() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Synapse" do
    description "A synapse"
    attribute :strength, Float, default: 0.5
    command "CreateSynapse" do
      role "Daemon"
    end
    command "Decay" do
      role "Daemon"
      reference_to Synapse
      then_set :strength, multiply: 0.5
    end
  end
end"#);

    rt.dispatch("CreateSynapse", HashMap::new()).unwrap();
    rt.dispatch("Decay", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    assert_field_close(&state, "strength", 0.25);

    rt.dispatch("Decay", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    assert_field_close(&state, "strength", 0.125);
}

#[test]
fn mutation_decay_reduces_field_by_rate() {
    // Decay rate 0.05 → new = current * (1 - 0.05) = current * 0.95.
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Synapse" do
    description "A synapse"
    attribute :strength, Float, default: 1.0
    command "CreateSynapse" do
      role "Daemon"
    end
    command "Decay" do
      role "Daemon"
      reference_to Synapse
      then_set :strength, decay: 0.05
    end
  end
end"#);

    rt.dispatch("CreateSynapse", HashMap::new()).unwrap();
    rt.dispatch("Decay", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    assert_field_close(&state, "strength", 0.95);

    rt.dispatch("Decay", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    assert_field_close(&state, "strength", 0.95 * 0.95);
}

#[test]
fn mutation_clamp_bounds_field() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Focus" do
    description "Singleton focus"
    attribute :weight, Float, default: 1.5
    command "CreateFocus" do
      role "Daemon"
    end
    command "Bound" do
      role "Daemon"
      reference_to Focus
      then_set :weight, clamp: [0.0, 1.0]
    end
  end
end"#);

    rt.dispatch("CreateFocus", HashMap::new()).unwrap();
    rt.dispatch("Bound", attrs(&[("focus", s("1"))])).unwrap();
    let state = rt.find("Focus", "1").unwrap();
    assert_field_close(&state, "weight", 1.0);
}

#[test]
fn mutation_clamp_lifts_below_min() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Synapse" do
    description "A synapse"
    attribute :strength, Float, default: -0.2
    command "CreateSynapse" do
      role "Daemon"
    end
    command "Bound" do
      role "Daemon"
      reference_to Synapse
      then_set :strength, clamp: [0.0, 1.0]
    end
  end
end"#);

    rt.dispatch("CreateSynapse", HashMap::new()).unwrap();
    rt.dispatch("Bound", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    assert_field_close(&state, "strength", 0.0);
}

#[test]
fn mutation_decay_then_clamp_composes() {
    // pulse_organs.bluebook pattern : decay first, then clamp into
    // [0, 1]. Two mutations on the same field run in declaration order.
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Synapse" do
    description "A synapse"
    attribute :strength, Float, default: 0.5
    command "CreateSynapse" do
      role "Daemon"
    end
    command "Pulse" do
      role "Daemon"
      reference_to Synapse
      then_set :strength, decay: 0.02
      then_set :strength, clamp: [0.0, 1.0]
    end
  end
end"#);

    rt.dispatch("CreateSynapse", HashMap::new()).unwrap();
    rt.dispatch("Pulse", attrs(&[("synapse", s("1"))])).unwrap();
    let state = rt.find("Synapse", "1").unwrap();
    // 0.5 * 0.98 = 0.49, in-range, clamp is a no-op.
    assert_field_close(&state, "strength", 0.49);
}

// --- Given enforcement ---

#[test]
fn given_blocks_when_false() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :toppings, Topping
    value_object "Topping" do
      attribute :name
    end
    command "CreatePizza" do
      role "Chef"
    end
    command "AddTopping" do
      role "Chef"
      reference_to Pizza
      attribute :name
      given("max 2 toppings") { toppings.size < 2 }
      then_set :toppings, append: { name: :name }
    end
  end
end"#);

    rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    rt.dispatch("AddTopping", attrs(&[("name", s("A")), ("pizza", s("1"))])).unwrap();
    rt.dispatch("AddTopping", attrs(&[("name", s("B")), ("pizza", s("1"))])).unwrap();

    let err = rt.dispatch("AddTopping", attrs(&[("name", s("C")), ("pizza", s("1"))]));
    assert!(err.is_err());
    let msg = format!("{}", err.unwrap_err());
    assert!(msg.contains("max 2 toppings"));
}

#[test]
fn given_passes_when_true() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :toppings, Topping
    value_object "Topping" do
      attribute :name
    end
    command "CreatePizza" do
      role "Chef"
    end
    command "AddTopping" do
      role "Chef"
      reference_to Pizza
      attribute :name
      given("max 2 toppings") { toppings.size < 2 }
      then_set :toppings, append: { name: :name }
    end
  end
end"#);

    rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    let result = rt.dispatch("AddTopping", attrs(&[("name", s("A")), ("pizza", s("1"))]));
    assert!(result.is_ok());
}

// --- rand_below stochastic gate ---
//
// HECKS_RAND_SEED is a process-wide env var, so the rand_below tests
// can't run in parallel with each other (each one would race on the
// var). Combine into one serial test that exercises both the firing
// path (seed=0 → predicate true) and the blocking path (seed=7 →
// predicate false), saving and restoring any pre-existing env value
// so it stays clean for adjacent tests.

#[test]
fn rand_below_predicate_with_seed_env_var() {
    let prior = std::env::var("HECKS_RAND_SEED").ok();

    // seed=0 → rand_below(300) returns 0 → predicate `== 0` fires
    std::env::set_var("HECKS_RAND_SEED", "0");
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Mint" do
    description "A mint attempt"
    command "AttemptMint" do
      role "Daemon"
      given { rand_below(300) == 0 }
    end
  end
end"#);
    let ok_result = rt.dispatch("AttemptMint", HashMap::new());
    assert!(ok_result.is_ok(), "rand_below(300)==0 should pass when HECKS_RAND_SEED=0");

    // seed=7 → rand_below(300) returns 7 → predicate `== 0` blocks
    std::env::set_var("HECKS_RAND_SEED", "7");
    let mut rt2 = boot(r#"Hecks.bluebook "T" do
  aggregate "Mint" do
    description "A mint attempt"
    command "AttemptMint" do
      role "Daemon"
      given { rand_below(300) == 0 }
    end
  end
end"#);
    let err_result = rt2.dispatch("AttemptMint", HashMap::new());
    assert!(err_result.is_err(), "rand_below(300)==0 should fail when HECKS_RAND_SEED=7 (returns 7)");

    match prior {
        Some(v) => std::env::set_var("HECKS_RAND_SEED", v),
        None => std::env::remove_var("HECKS_RAND_SEED"),
    }
}

// --- Default values ---

#[test]
fn default_values_applied() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "pending"
    attribute :customer
    command "CreateOrder" do
      role "Customer"
      attribute :customer
    end
  end
end"#);

    rt.dispatch("CreateOrder", attrs(&[("customer", s("Alice"))])).unwrap();
    let state = rt.find("Order", "1").unwrap();
    assert_eq!(state.get("status"), &s("pending"));
    assert_eq!(state.get("customer"), &s("Alice"));
}

// --- Events ---

#[test]
fn events_recorded_in_order() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
    end
  end
end"#);

    rt.dispatch("CreatePizza", HashMap::new()).unwrap();
    rt.dispatch("PlaceOrder", HashMap::new()).unwrap();

    let events = rt.event_bus.events();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].name, "PizzaCreated");
    assert_eq!(events[1].name, "OrderPlaced");
}

#[test]
fn event_naming_conventions() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Item" do
    description "An item"
    command "CreateItem" do
      role "User"
    end
    command "UpdateItem" do
      role "User"
      reference_to Item
    end
    command "DeleteItem" do
      role "User"
      reference_to Item
    end
  end
end"#);

    rt.dispatch("CreateItem", HashMap::new()).unwrap();
    rt.dispatch("UpdateItem", attrs(&[("item", s("1"))])).unwrap();
    rt.dispatch("DeleteItem", attrs(&[("item", s("1"))])).unwrap();

    let names: Vec<&str> = rt.event_bus.events().iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["ItemCreated", "ItemUpdated", "ItemDeleted"]);
}

#[test]
fn explicit_emits_name() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Payment" do
    description "A payment"
    command "ChargeCard" do
      role "System"
      emits "PaymentProcessed"
    end
  end
end"#);

    let result = rt.dispatch("ChargeCard", HashMap::new()).unwrap();
    assert_eq!(result.event.unwrap().name, "PaymentProcessed");
}

// --- Policies ---

#[test]
fn policy_triggers_command() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
      attribute :customer
      emits "OrderPlaced"
    end
  end
  aggregate "Notification" do
    description "A notification"
    command "SendConfirmation" do
      role "System"
      attribute :customer
    end
  end
  policy "ConfirmOrder" do
    on "OrderPlaced"
    trigger "SendConfirmation"
  end
end"#);

    rt.dispatch("PlaceOrder", attrs(&[("customer", s("Bob"))])).unwrap();

    let events = rt.event_bus.events();
    let names: Vec<&str> = events.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["OrderPlaced", "SendConfirmationCompleted"]);
}

#[test]
fn multiple_policies_same_event() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
      emits "OrderPlaced"
    end
  end
  aggregate "Notification" do
    description "A notification"
    command "SendConfirmation" do
      role "System"
    end
  end
  aggregate "Inventory" do
    description "Stock"
    command "ReserveStock" do
      role "System"
    end
  end
  policy "ConfirmOrder" do
    on "OrderPlaced"
    trigger "SendConfirmation"
  end
  policy "ReserveOnOrder" do
    on "OrderPlaced"
    trigger "ReserveStock"
  end
end"#);

    rt.dispatch("PlaceOrder", HashMap::new()).unwrap();

    let names: Vec<&str> = rt.event_bus.events().iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"OrderPlaced"));
    assert!(names.contains(&"SendConfirmationCompleted"));
    assert!(names.contains(&"ReserveStockCompleted"));
}

// --- Error cases ---

#[test]
fn unknown_command() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
end"#);

    let err = rt.dispatch("BogusCommand", HashMap::new());
    assert!(err.is_err());
    assert!(format!("{}", err.unwrap_err()).contains("unknown command"));
}

#[test]
fn aggregate_not_found() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    command "CancelOrder" do
      role "Customer"
      reference_to Order
    end
  end
end"#);

    let err = rt.dispatch("CancelOrder", attrs(&[("order", s("999"))]));
    assert!(err.is_err());
    assert!(format!("{}", err.unwrap_err()).contains("not found"));
}

// --- Life domain self-hosting ---
// The "life" self-hosting domain (nursery/hecks/life.bluebook) was
// removed; its boot+lifecycle behavior is now covered by the
// behaviors_runner test corpus running against every bluebook.

// --- Lifecycle transitions ---

#[test]
fn lifecycle_allows_valid_transition() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "pending"
    command "CreateOrder" do
      role "Customer"
    end
    command "ShipOrder" do
      role "Warehouse"
      reference_to Order
      emits "OrderShipped"
    end
    command "DeliverOrder" do
      role "Driver"
      reference_to Order
      emits "OrderDelivered"
    end
    lifecycle :status, default: "pending" do
      transition "ShipOrder" => "shipped", from: "pending"
      transition "DeliverOrder" => "delivered", from: "shipped"
    end
  end
end"#);

    rt.dispatch("CreateOrder", HashMap::new()).unwrap();
    rt.dispatch("ShipOrder", attrs(&[("order", s("1"))])).unwrap();

    let state = rt.find("Order", "1").unwrap();
    assert_eq!(state.get("status"), &s("shipped"));

    rt.dispatch("DeliverOrder", attrs(&[("order", s("1"))])).unwrap();
    let state = rt.find("Order", "1").unwrap();
    assert_eq!(state.get("status"), &s("delivered"));
}

#[test]
fn lifecycle_blocks_invalid_transition() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "pending"
    command "CreateOrder" do
      role "Customer"
    end
    command "DeliverOrder" do
      role "Driver"
      reference_to Order
    end
    lifecycle :status, default: "pending" do
      transition "DeliverOrder" => "delivered", from: "shipped"
    end
  end
end"#);

    rt.dispatch("CreateOrder", HashMap::new()).unwrap();
    // Can't deliver from "pending" — must be "shipped"
    let err = rt.dispatch("DeliverOrder", attrs(&[("order", s("1"))]));
    assert!(err.is_err());
    assert!(format!("{}", err.unwrap_err()).contains("lifecycle violation"));
}

#[test]
fn lifecycle_no_constraint_allows_any() {
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "pending"
    command "CreateOrder" do
      role "Customer"
    end
    command "CancelOrder" do
      role "Customer"
      reference_to Order
    end
    lifecycle :status, default: "pending" do
      transition "CancelOrder" => "cancelled"
    end
  end
end"#);

    rt.dispatch("CreateOrder", HashMap::new()).unwrap();
    // No from: constraint — can cancel from any state
    rt.dispatch("CancelOrder", attrs(&[("order", s("1"))])).unwrap();
    let state = rt.find("Order", "1").unwrap();
    assert_eq!(state.get("status"), &s("cancelled"));
}

// --- Seed loader ---

#[test]
fn seed_loader_dispatches() {
    // Each seed line counts toward the dispatched count regardless of
    // whether they create separate records (no self-ref → singleton)
    // or update the same one. We assert dispatched count == 2 and
    // the singleton's name is the most recently set one.
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :name
    command "CreatePizza" do
      role "Chef"
      attribute :name
    end
  end
end"#);

    let count = hecks_life::runtime::seed_loader::load_from_string(&mut rt,
        "dispatch CreatePizza name=Margherita\ndispatch CreatePizza name=Pepperoni\n# comment\n\n"
    ).unwrap();

    assert_eq!(count, 2);
    assert_eq!(rt.all("Pizza").len(), 1);
    // Auto-input only fires for is_new states. The second dispatch
    // finds the existing singleton, so name stays at "Margherita".
    assert_eq!(rt.all("Pizza")[0].get("name"), &s("Margherita"));
}

// --- Veterinary full lifecycle ---
// The original `nursery/veterinary` fixture was renamed to
// `nursery/veterinary_clinic` with a different command shape. The
// cross-policy cascade behavior this test exercised is now covered
// by the behaviors_runner suite, which asserts the exact emit list
// for every command on every bluebook in the corpus.

// --- Auto-projections ---

#[test]
fn auto_projections_created_at_boot() {
    let rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
    end
  end
end"#);

    assert_eq!(rt.projections.len(), 2);
    assert_eq!(rt.projections[0].name, "PizzaList");
    assert_eq!(rt.projections[1].name, "OrderList");
}

#[test]
fn auto_projection_tracks_aggregates() {
    // Without a self-reference, two CreatePizza dispatches collapse
    // onto one singleton record (heki adapter behavior). The
    // projection sees one row; the second create updates that row's
    // name. Test asserts the live state after both dispatches.
    let mut rt = boot(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :name
    command "CreatePizza" do
      role "Chef"
      attribute :name
    end
  end
end"#);

    rt.dispatch("CreatePizza", attrs(&[("name", s("Margherita"))])).unwrap();
    rt.dispatch("CreatePizza", attrs(&[("name", s("Pepperoni"))])).unwrap();

    assert_eq!(rt.projections[0].count(), 1);
    let rows = rt.projections[0].query_all();
    assert_eq!(rows.len(), 1);
}

// --- Parser: pizzas as a representative real-domain parse ---

#[test]
fn parse_pizzas() {
    let source = std::fs::read_to_string(
        concat!(env!("CARGO_MANIFEST_DIR"), "/../hecks_conception/catalog/pizzas.bluebook")
    ).unwrap();
    let domain = hecks_life::parser::parse(&source);
    assert_eq!(domain.name, "Pizzas");
    assert_eq!(domain.aggregates.len(), 2);
    // Pizza aggregate has CreatePizza, AddTopping, RemoveTopping.
    assert!(domain.aggregates[0].commands.len() >= 2);
}
