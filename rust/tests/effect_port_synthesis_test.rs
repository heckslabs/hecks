//! Effect-port wiring (bucket-3 E2) — a resolved `charged_by` binding is
//! translated into a DrivenAdapter the mature driven-adapter resolver executes.
//!
//! These tests pin the TRANSLATION (binding → DrivenAdapter). The resolver that
//! then FIRES the synthesised adapter on the triggering event is already pinned
//! by driven_adapter_canned_world_test / driven_adapter_fan_out_test ; this is
//! the new seam between the hexagon binding surface and that executor.
//!
//! SCOPE : the success branch (`into[0]`) only — the round-trip WIRING. Mapping a
//! real gateway verdict to success/failure (`into[1]`) is the deferred second
//! sub-decision.

use storehouse::hecksagon_parser;
use storehouse::runtime::hexagon_resolution::synthesize_effect_driven_adapters;

const PERSISTENCE_FAMILY: &str =
    "Hecks.family \"persistence\" do\n  verb \"persisted_by\"\n  signal :reply\n  field :dir\nend\n";
const PAYMENT_FAMILY: &str = "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\n  field :endpoint\nend\n";
const HEKI_ADAPTER: &str = "Hecks.adapter \"Heki\" do\n  family \"persistence\"\nend\n";
const STRIPE_ADAPTER: &str = "Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n";
const PIZZAS_HEX: &str = "Hecks.hecksagon \"Pizzas\" do\n  Pizzas::Order.persisted_by(\"Heki\")\n  Pizzas::Order.charged_by(\"Stripe\", on: \"OrderPlaced\", into: \"Order.Authorize | Order.Decline\")\nend\n";

fn books() -> Vec<storehouse::hecksagon_ir::Hecksagon> {
    vec![
        hecksagon_parser::parse(PERSISTENCE_FAMILY),
        hecksagon_parser::parse(PAYMENT_FAMILY),
        hecksagon_parser::parse(HEKI_ADAPTER),
        hecksagon_parser::parse(STRIPE_ADAPTER),
        hecksagon_parser::parse(PIZZAS_HEX),
    ]
}

#[test]
fn charged_by_binding_synthesises_a_driven_adapter_for_the_success_verdict() {
    let mut hecksagons = books();
    synthesize_effect_driven_adapters(&mut hecksagons);

    // The synthesised adapter lands on the hecksagon that owns the bind (Pizzas).
    let pizzas = hecksagons
        .iter()
        .find(|h| h.name == "Pizzas")
        .expect("Pizzas hecksagon present");
    assert_eq!(
        pizzas.driven_adapters.len(),
        1,
        "exactly one effect bind (charged_by) synthesises one driven adapter; the reply bind (persisted_by) synthesises none",
    );

    let adapter = &pizzas.driven_adapters[0];
    assert_eq!(adapter.name, "Stripe", "named for the bound adapter");
    assert_eq!(adapter.handlers.len(), 1);

    let handler = &adapter.handlers[0];
    assert_eq!(
        handler.event_ref, "OrderPlaced",
        "fires on the bind's triggering event",
    );
    assert_eq!(handler.dispatches.len(), 1, "one follow-on: the success verdict");
    assert_eq!(
        handler.dispatches[0].command, "Pizzas::Order.Authorize",
        "the success verdict (into[0]) qualified with the bind's context",
    );
}

#[test]
fn reply_only_hexagon_synthesises_nothing() {
    // persisted_by is a reply port — no `on`, no `into` — so nothing is driven.
    let mut hecksagons = vec![
        hecksagon_parser::parse(PERSISTENCE_FAMILY),
        hecksagon_parser::parse(HEKI_ADAPTER),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Pizzas\" do\n  Pizzas::Order.persisted_by(\"Heki\")\nend\n",
        ),
    ];
    synthesize_effect_driven_adapters(&mut hecksagons);
    assert!(
        hecksagons.iter().all(|h| h.driven_adapters.is_empty()),
        "a reply-only hexagon drives no adapters",
    );
}

#[test]
fn unresolved_effect_bind_synthesises_nothing() {
    // charged_by("Ghost") — no adapter declares Ghost, so the typed attach
    // checkpoint fails and nothing is synthesised (no half-wired driven edge).
    let mut hecksagons = vec![
        hecksagon_parser::parse(PAYMENT_FAMILY),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Pizzas\" do\n  Pizzas::Order.charged_by(\"Ghost\", on: \"OrderPlaced\", into: \"Order.Authorize | Order.Decline\")\nend\n",
        ),
    ];
    synthesize_effect_driven_adapters(&mut hecksagons);
    assert!(
        hecksagons.iter().all(|h| h.driven_adapters.is_empty()),
        "an unresolved adapter synthesises no driven edge",
    );
}
