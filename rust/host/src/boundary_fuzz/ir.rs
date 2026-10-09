//! Seeded fuzz of the IR sidecar readers: `ir.json` is generated, but it is read from disk at
//! boot, so a stale, hand-edited or truncated file must come back as `None` or a refusal, never
//! a panic.

use super::*;
use crate::commerce_ir::*;
use crate::fuzz_support::*;
use serde_json::json;

const KEYS: &[&str] = &[
    "name", "aggregates", "lineage", "capable_aggregates", "storage_name", "persistence", "adapter", "authorization", "grant", "assignment_aggregate", "membership", "provider", "aggregate",
    "identity", "register", "link", "resolve", "newsletter", "subscribe", "add_name", "confirm", "unsubscribe", "newsletter_issues", "issue_aggregate", "schedule", "send_issue", "record_delivery",
    "payments", "initiate", "succeeded", "failed", "event_aggregate", "registrations", "registration_aggregate", "request", "payment_connection", "commands", "attributes",
];

/// An object over the keys the readers look up, with each value the right shape, the wrong
/// shape, or missing: the mix that finds a reader trusting its input.
fn random_ir(rng: &mut Rng, depth: usize) -> Value {
    let mut fields = serde_json::Map::new();
    for key in KEYS {
        if rng.chance(3) {
            continue;
        }
        let value = match rng.below(5) {
            0 if depth < 2 => random_ir(rng, depth + 1),
            1 => Value::String(random_text(rng)),
            2 => Value::Array((0..rng.below(2)).map(|_| if depth < 2 { random_ir(rng, depth + 1) } else { Value::Null }).collect()),
            3 => json!(*rng.pick(&["Postgres", "PostgresEra", "Heki", "Memory", ""])),
            _ => random_value(rng, 2),
        };
        fields.insert(key.to_string(), value);
    }
    Value::Object(fields)
}

#[test]
fn every_provider_reader_answers_any_ir_shape() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..40 {
                let ir = if rng.chance(8) { random_value(&mut rng, 0) } else { random_ir(&mut rng, 0) };
                let _ = lineage_capable_aggregates(&ir);
                let _ = persistence_adapters(&ir);
                let _ = mirrored_aggregates(&ir);
                let _ = authorization_provider(&ir);
                let _ = membership_provider(&ir);
                let _ = identity_provider(&ir);
                let _ = command_declares(&ir, &random_text(&mut rng), &random_text(&mut rng), &random_text(&mut rng));
                let _ = newsletter_provider(&ir).map(|p| p.instance_prefix());
                let _ = newsletter_issues_provider(&ir).map(|p| p.issue_prefix());
                let _ = payments_provider(&ir).map(|p| p.instance_prefix());
                let _ = checkout_windows(&ir);
                if let Some(p) = registrations_provider(&ir) {
                    let _ = (p.event_prefix(), p.registration_prefix(), p.request_target());
                }
                if let Some(p) = payment_connection_provider(&ir) {
                    let _ = p.instance_prefix();
                }
                let _ = registrations_binding(&random_text(&mut rng));
                let _ = payment_connection_binding(&random_text(&mut rng));
                if let Err(message) = refuse_unsupported_persistence_adapters(&ir) {
                    assert!(message.contains("rust/host only has a backend"), "seed {seed}: unhelpful refusal {message:?}");
                }
            }
        });
    }
}

#[test]
fn an_unsupported_persistence_adapter_is_always_refused_at_boot() {
    for adapter in ["Heki", "Memory", "Sqlite", "", "postgres", "Postgres "] {
        let ir = json!({"name": "D", "persistence": {"aggregates": [{"name": "A", "adapter": adapter}]}});
        assert!(refuse_unsupported_persistence_adapters(&ir).is_err(), "{adapter:?}");
    }
    for adapter in ["Postgres", "PostgresEra"] {
        let ir = json!({"name": "D", "persistence": {"aggregates": [{"name": "A", "adapter": adapter}]}});
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok(), "{adapter:?}");
    }
}
