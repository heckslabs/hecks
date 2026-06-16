//! Hexagon-binding persistence consult (bucket-3 step 4) — repository-mint OBEYS
//! the port-verb binding surface.
//!
//! The north-star `Pizzas::Order.persisted_by("Heki")` lights up here : steps 1-3
//! parse + resolve the binding ; THIS step consults it at boot so the runtime mints
//! the backend the adapter NAMES rather than coinciding with the heki default. The
//! discriminating proof is the Memory case — a `persisted_by("Memory")` binding
//! flips Pizzas::Order to Backend::Memory, which the heki default never would.

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{BackendKind, Runtime};
use std::fs;

// The persistence family + its two adapters, declared as framework vocabulary the
// resolver reads as IR (bucket-3). resolve_bindings flat-maps families + adapters
// across every attached hecksagon, so declaring them here is enough.
const PERSISTENCE_FAMILY: &str =
    "Hecks.family \"persistence\" do\n  verb \"persisted_by\"\n  signal :reply\n  field :dir\nend\n";
const MEMORY_ADAPTER: &str = "Hecks.adapter \"Memory\" do\n  family \"persistence\"\nend\n";
const HEKI_ADAPTER: &str = "Hecks.adapter \"Heki\" do\n  family \"persistence\"\nend\n";

fn pizzas_bluebook() -> String {
    let path = format!(
        "{}/../examples/pizzas/bluebook/pizzas.bluebook",
        env!("CARGO_MANIFEST_DIR")
    );
    fs::read_to_string(&path).expect("pizzas.bluebook readable")
}

// Boot the real Pizzas domain with the persistence family + the named adapter +
// one `Pizzas::Order.persisted_by(<adapter>)` binding attached.
fn boot_with_order_binding(adapter: &str) -> Runtime {
    let domain = parser::parse(&pizzas_bluebook());
    let binding_hex = format!(
        "Hecks.hecksagon \"Pizzas\" do\n  Pizzas::Order.persisted_by(\"{}\")\nend\n",
        adapter
    );
    Runtime::boot_with_hecksagons(
        domain,
        Some("/tmp/hexagon_consult_gate".into()),
        vec![
            hecksagon_parser::parse(PERSISTENCE_FAMILY),
            hecksagon_parser::parse(MEMORY_ADAPTER),
            hecksagon_parser::parse(HEKI_ADAPTER),
            hecksagon_parser::parse(&binding_hex),
        ],
    )
}

#[test]
fn binding_memory_flips_order_to_backend_memory() {
    // The discriminating case : without the consult, Pizzas::Order would resolve
    // to the heki default boot_with_data_dir built. Asserting Memory proves the
    // consult ran AND drove the backend from the binding's adapter.
    let rt = boot_with_order_binding("Memory");
    let map = rt.dump_backend_map();
    let order = map
        .iter()
        .find(|b| b.repo_key == "Pizzas::Order")
        .expect("Pizzas::Order has a repository");
    assert_eq!(
        order.kind,
        BackendKind::Memory,
        "the persisted_by(\"Memory\") binding mints Backend::Memory, overriding the heki default",
    );
    assert_eq!(order.heki_path, None, "a memory-backed repo has no heki path");
}

#[test]
fn binding_leaves_unbound_aggregate_on_heki_default() {
    // Additive : only the BOUND aggregate (Order) flips ; Pizza, with no binding,
    // keeps the heki repository boot_with_data_dir built.
    let rt = boot_with_order_binding("Memory");
    let map = rt.dump_backend_map();
    let pizza = map
        .iter()
        .find(|b| b.repo_key == "Pizzas::Pizza")
        .expect("Pizzas::Pizza has a repository");
    assert_eq!(
        pizza.kind,
        BackendKind::Heki,
        "an aggregate with no persistence binding keeps the heki default",
    );
}

#[test]
fn binding_heki_mints_heki_at_data_dir() {
    // The north-star literal : persisted_by("Heki") resolves to the heki backend
    // at the runtime data_dir — now binding-driven, byte-identical to the default.
    let rt = boot_with_order_binding("Heki");
    let map = rt.dump_backend_map();
    let order = map
        .iter()
        .find(|b| b.repo_key == "Pizzas::Order")
        .expect("Pizzas::Order has a repository");
    assert_eq!(order.kind, BackendKind::Heki);
    assert_eq!(
        order.heki_path.as_deref(),
        Some("/tmp/hexagon_consult_gate"),
        "the heki binding mints heki at the runtime data_dir",
    );
}
