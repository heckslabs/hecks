//! The framework outbox is grafted onto a domain ONLY when that domain itself
//! declares an effect port — never because some OTHER domain does.
//!
//! `serve_directory` deliberately loads every hecksagon under the served tree
//! AND under the running repo, so the runtime routinely boots a domain with a
//! pile of hecksagons that have nothing to do with it. `ensure_outbox_substrate`
//! used to ask only "does ANY attached hecksagon carry an effect binding?", so
//! a single `charged_by` anywhere in the monorepo grafted OutboundEvent onto
//! EVERY served domain — which is why ToolShed, declaring no effect port at
//! all, rendered the framework outbox as one of its own modules.
//!
//! Both directions are pinned here. The negative case alone would pass just as
//! well if the graft were deleted outright, and deleting it would break the
//! standalone-served effect domain that genuinely needs an outbox to record
//! deliveries into. It is the PAIR that specifies the behaviour.

use storehouse::runtime::Runtime;
use storehouse::{hecksagon_parser, parser};

/// A domain with no effect port of its own — the ToolShed shape.
const SHED: &str = r#"Hecks.bluebook "Shed" do
  aggregate "Loan" do
    identified_by :id
    attribute :id, LoanId
    value_object "LoanId" do
      attribute :value, String
    end
    command "Open" do
      role "Member"
      attribute :id, LoanId
    end
  end
end
"#;

/// A domain that DOES declare an effect port, on its own aggregate.
const SHOP: &str = r#"Hecks.bluebook "Shop" do
  aggregate "Order" do
    identified_by :id
    attribute :id, OrderId
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

/// The payment family + Stripe adapter + a Shop effect binding — the set a
/// repo-wide hecksagon sweep hands to EVERY served runtime.
fn shop_effect_hecksagons() -> Vec<storehouse::hecksagon_ir::Hecksagon> {
    vec![
        hecksagon_parser::parse(
            "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n",
        ),
        hecksagon_parser::parse("Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n"),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Shop\" do\n  Shop::Order.charged_by(\"Stripe\", on: \"OrderPlaced\") do\n    success \"Order.Authorize\"\n    failure \"Order.Decline\"\n  end\nend\n",
        ),
    ]
}

fn aggregate_names(rt: &Runtime) -> Vec<String> {
    rt.domain.aggregates.iter().map(|a| a.name.clone()).collect()
}

#[test]
fn a_foreign_effect_binding_does_not_graft_the_outbox() {
    // Shed declares no effect port. The Shop binding below is a STRANGER to it,
    // exactly as every repo hecksagon is a stranger to every served domain.
    let rt = Runtime::boot_with_hecksagons(parser::parse(SHED), None, shop_effect_hecksagons());
    let names = aggregate_names(&rt);
    assert!(
        !names.iter().any(|n| n == "OutboundEvent"),
        "Shed declares no effect port, so the framework outbox must not appear \
         among its aggregates — a foreign domain's binding is not Shed's \
         business (got {:?})",
        names,
    );
    assert!(names.iter().any(|n| n == "Loan"), "Shed keeps its own aggregate");
}

#[test]
fn a_domains_own_effect_binding_still_grafts_the_outbox() {
    // The other half of the contract : scoping must not become deletion. A
    // standalone-served effect domain still needs the outbox to record its
    // deliveries into, and nothing else supplies it on a single-bluebook boot.
    let rt = Runtime::boot_with_hecksagons(parser::parse(SHOP), None, shop_effect_hecksagons());
    let names = aggregate_names(&rt);
    assert!(
        names.iter().any(|n| n == "OutboundEvent"),
        "Shop::Order.charged_by is Shop's OWN effect port, so Shop must get the \
         framework outbox to record deliveries into (got {:?})",
        names,
    );
}
