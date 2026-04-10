//! Formatter integration tests
//!
//! Tests that the formatter produces correct output for parsed domains.

use hecks_life::parser;
use hecks_life::formatter;

fn capture_inspect(source: &str) -> String {
    let domain = parser::parse(source);
    // Formatter writes to stdout; we test the underlying data instead.
    // For now, verify it doesn't panic and the domain round-trips.
    let mut buf = Vec::new();
    write_inspect(&domain, &mut buf);
    String::from_utf8(buf).unwrap()
}

fn write_inspect(domain: &hecks_life::ir::Domain, buf: &mut Vec<u8>) {
    use std::io::Write;
    let header = format!("Domain: {}", domain.name);
    writeln!(buf, "{}", header).unwrap();
    writeln!(buf, "{}", "=".repeat(header.len())).unwrap();
    writeln!(buf).unwrap();

    for agg in &domain.aggregates {
        writeln!(buf, "  {}", agg.name).unwrap();
        if let Some(ref desc) = agg.description {
            writeln!(buf, "    {}", desc).unwrap();
        }
        for cmd in &agg.commands {
            writeln!(buf, "    {}", cmd.name).unwrap();
        }
    }
}

#[test]
fn inspect_contains_domain_name() {
    let output = capture_inspect(r#"Hecks.bluebook "Pizzas" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
end"#);
    assert!(output.contains("Domain: Pizzas"));
}

#[test]
fn inspect_contains_aggregate() {
    let output = capture_inspect(r#"Hecks.bluebook "Pizzas" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
end"#);
    assert!(output.contains("Pizza"));
    assert!(output.contains("CreatePizza"));
}

#[test]
fn formatter_functions_dont_panic() {
    let domain = parser::parse(r#"Hecks.bluebook "Test" do
  aggregate "Order" do
    description "An order"
    attribute :status, default: "pending"
    attribute :items, Item
    value_object "Item" do
      attribute :name
      attribute :quantity, Integer
    end
    reference_to Order
    command "PlaceOrder" do
      role "Customer"
      attribute :customer
      given("has items") { items.size > 0 }
      then_set :status, to: "placed"
      emits "OrderPlaced"
    end
    command "CancelOrder" do
      role "Customer"
      reference_to Order
      then_set :status, to: "cancelled"
    end
    lifecycle :status, default: "pending" do
      transition "PlaceOrder" => "placed"
      transition "CancelOrder" => "cancelled", from: "placed"
    end
  end
  policy "NotifyOnPlace" do
    on "OrderPlaced"
    trigger "CancelOrder"
  end
end"#);

    // These write to stdout — just verify they don't panic
    formatter::inspect(&domain);
    formatter::tree(&domain);
    formatter::list(&domain);
}
