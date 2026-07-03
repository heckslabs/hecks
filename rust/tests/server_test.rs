//! Server route tests
//!
//! Tests the HTTP routing logic directly without starting a TCP server.
//! Each test boots a domain, wraps the runtime in RefCell, and calls route().

use storehouse::parser;
use storehouse::runtime::acl_readmodel::DoorPosture;
use storehouse::runtime::Runtime;
use storehouse::server;
use std::cell::RefCell;

fn boot(source: &str) -> RefCell<Runtime> {
    let domain = parser::parse(source);
    RefCell::new(Runtime::boot(domain))
}

/// Every pre-existing route test calls through an OPEN door with no bearer —
/// the header-less local-studio case, which must stay byte-identical to the
/// pre-client-door behavior (these unchanged assertions ARE that proof).
fn route(method: &str, path: &str, body: &str, rt: &RefCell<Runtime>) -> (&'static str, String) {
    server::route(method, path, body, None, DoorPosture::Open, rt)
}

const PIZZAS: &str = r#"Hecks.bluebook "Pizzas" do
  aggregate "Pizza" do
    description "A pizza"
    attribute :name
    command "CreatePizza" do
      role "Chef"
      attribute :name
    end
  end
  aggregate "Order" do
    description "An order"
    command "PlaceOrder" do
      role "Customer"
      emits "OrderPlaced"
    end
  end
  policy "NotifyOnOrder" do
    on "OrderPlaced"
    trigger "CreatePizza"
  end
end"#;

#[test]
fn health_check() {
    let rt = boot(PIZZAS);
    let (status, body) = route("GET", "/health", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains("ok"));
}

#[test]
fn domain_info() {
    let rt = boot(PIZZAS);
    let (status, body) = route("GET", "/domain", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains("Pizzas"));
    assert!(body.contains("Pizza"));
    assert!(body.contains("CreatePizza"));
}

#[test]
fn dispatch_creates_aggregate() {
    let rt = boot(PIZZAS);
    let body = r#"{"command": "CreatePizza", "attrs": {"name": "Margherita"}}"#;
    let (status, resp) = route("POST", "/dispatch", body, &rt);
    assert_eq!(status, "200 OK");
    assert!(resp.contains(r#""ok":true"#));
    assert!(resp.contains(r#""aggregate_type":"Pizza""#));
    assert!(resp.contains(r#""aggregate_id":"1""#));
}

#[test]
fn dispatch_unknown_command() {
    let rt = boot(PIZZAS);
    let body = r#"{"command": "BogusCommand", "attrs": {}}"#;
    let (status, resp) = route("POST", "/dispatch", body, &rt);
    assert_eq!(status, "422 Unprocessable Entity");
    assert!(resp.contains("unknown command"));
}

#[test]
fn get_aggregates_empty() {
    let rt = boot(PIZZAS);
    let (status, body) = route("GET", "/aggregates/Pizza", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains(r#""count":0"#));
}

#[test]
fn get_aggregates_after_create() {
    let rt = boot(PIZZAS);
    let create = r#"{"command": "CreatePizza", "attrs": {"name": "Pepperoni"}}"#;
    route("POST", "/dispatch", create, &rt);

    let (status, body) = route("GET", "/aggregates/Pizza", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains(r#""count":1"#));
}

#[test]
fn get_aggregate_by_id() {
    let rt = boot(PIZZAS);
    let create = r#"{"command": "CreatePizza", "attrs": {"name": "Diavola"}}"#;
    route("POST", "/dispatch", create, &rt);

    let (status, body) = route("GET", "/aggregates/Pizza/1", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains(r#""id":"1""#));
}

#[test]
fn get_aggregate_not_found() {
    let rt = boot(PIZZAS);
    let (status, body) = route("GET", "/aggregates/Pizza/999", "", &rt);
    assert_eq!(status, "404 Not Found");
    assert!(body.contains("not found"));
}

#[test]
fn get_events() {
    let rt = boot(PIZZAS);
    let create = r#"{"command": "CreatePizza", "attrs": {"name": "M"}}"#;
    route("POST", "/dispatch", create, &rt);

    let (status, body) = route("GET", "/events", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains("PizzaCreated"));
}

#[test]
fn get_policies() {
    let rt = boot(PIZZAS);
    let (status, body) = route("GET", "/policies", "", &rt);
    assert_eq!(status, "200 OK");
    assert!(body.contains("NotifyOnOrder"));
    assert!(body.contains("OrderPlaced"));
}

#[test]
fn unknown_route() {
    let rt = boot(PIZZAS);
    let (status, _) = route("GET", "/nope", "", &rt);
    assert_eq!(status, "404 Not Found");
}
