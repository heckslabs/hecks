//! Hexagon resolution tests — the typed attach checkpoint (bucket-3 step 3).
//!
//! A bind `aggregate.verb("Adapter")` resolves IFF the named adapter's
//! family carries `verb`. These pin every outcome the resolver can reach,
//! built from real parsed `.hecksagon` / `.family` / `.adapter` sources so
//! the parser and the resolver are exercised together.

use storehouse::hecksagon_parser::parse;
use storehouse::hecksagon_ir::Hecksagon;
use storehouse::runtime::hexagon_resolution::{resolve_bindings, ResolveOutcome};

fn hex(src: &str) -> Hecksagon {
    parse(src)
}

const PERSISTENCE_FAMILY: &str = "Hecks.family \"persistence\" do\n  verb \"persisted_by\"\n  signal :reply\n  field :dir\nend\n";
const PAYMENT_FAMILY: &str = "Hecks.family \"payment\" do\n  verb \"charged_by\"\n  signal :effect\nend\n";
const HEKI_ADAPTER: &str = "Hecks.adapter \"Heki\" do\n  family \"persistence\"\nend\n";
const STRIPE_ADAPTER: &str = "Hecks.adapter \"Stripe\" do\n  family \"payment\"\nend\n";

const PIZZAS_HEX: &str = "Hecks.hecksagon \"Pizzas\" do\n  Pizzas::Pizza.persisted_by(\"Heki\")\n  Pizzas::Order.persisted_by(\"Heki\")\n  Pizzas::Order.charged_by(\"Stripe\", on: \"OrderPlaced\")\nend\n";

#[test]
fn resolves_reply_and_effect_binds_through_their_families() {
    let books = vec![
        hex(PIZZAS_HEX),
        hex(PERSISTENCE_FAMILY),
        hex(PAYMENT_FAMILY),
        hex(HEKI_ADAPTER),
        hex(STRIPE_ADAPTER),
    ];
    let verdicts = resolve_bindings(&books);
    assert_eq!(verdicts.len(), 3, "three binds in pizzas");
    assert!(verdicts.iter().all(|r| r.is_ok()), "all three resolve");

    let charge = verdicts.iter().find(|r| r.verb == "charged_by").unwrap();
    assert_eq!(
        charge.outcome,
        ResolveOutcome::Resolved { family: "payment".to_string() },
        "the effect bind resolves through payment"
    );
    let persist = verdicts.iter().find(|r| r.verb == "persisted_by").unwrap();
    assert_eq!(
        persist.outcome,
        ResolveOutcome::Resolved { family: "persistence".to_string() },
    );
}

#[test]
fn verb_mismatch_when_adapter_family_lacks_the_verb() {
    // persisted_by on Stripe — Stripe's family is payment (charged_by), so
    // the typed attach checkpoint fails loudly.
    let bad = "Hecks.hecksagon \"X\" do\n  X::Y.persisted_by(\"Stripe\")\nend\n";
    let books = vec![hex(bad), hex(PAYMENT_FAMILY), hex(STRIPE_ADAPTER)];
    let verdicts = resolve_bindings(&books);
    assert_eq!(verdicts.len(), 1);
    assert_eq!(
        verdicts[0].outcome,
        ResolveOutcome::VerbMismatch {
            family: "payment".to_string(),
            family_verb: "charged_by".to_string(),
        },
    );
    assert!(!verdicts[0].is_ok());
}

#[test]
fn unknown_adapter_when_none_declared() {
    let books = vec![hex("Hecks.hecksagon \"X\" do\n  X::Y.persisted_by(\"Ghost\")\nend\n")];
    let verdicts = resolve_bindings(&books);
    assert_eq!(verdicts[0].outcome, ResolveOutcome::UnknownAdapter);
    assert!(!verdicts[0].is_ok());
}

#[test]
fn adapter_family_missing_when_family_undeclared() {
    // Heki declares family persistence, but no .family declares it.
    let books = vec![
        hex("Hecks.hecksagon \"X\" do\n  X::Y.persisted_by(\"Heki\")\nend\n"),
        hex(HEKI_ADAPTER),
    ];
    let verdicts = resolve_bindings(&books);
    assert_eq!(
        verdicts[0].outcome,
        ResolveOutcome::AdapterFamilyMissing { family: "persistence".to_string() },
    );
}
