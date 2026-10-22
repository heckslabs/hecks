//! Seeded fuzz of the IR sidecar readers: `ir.json` is generated, but it is read from disk at
//! boot, so a stale, hand-edited or truncated file must come back as `None` or a refusal, never
//! a panic.

use super::*;
use crate::commerce_ir::*;
use crate::fuzz_support::*;
use serde_json::json;

const KEYS: &[&str] = &[
    "name",
    "aggregates",
    "lineage",
    "capable_aggregates",
    "storage_name",
    "persistence",
    "adapter",
    "adapters",
    "port",
    "authorization",
    "grant",
    "assignment_aggregate",
    "membership",
    "provider",
    "aggregate",
    "identity",
    "register",
    "link",
    "resolve",
    "newsletter",
    "subscribe",
    "add_name",
    "confirm",
    "unsubscribe",
    "newsletter_issues",
    "issue_aggregate",
    "schedule",
    "send_issue",
    "record_delivery",
    "payments",
    "initiate",
    "succeeded",
    "failed",
    "event_aggregate",
    "registrations",
    "registration_aggregate",
    "request",
    "payment_connection",
    "commands",
    "attributes",
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
            2 => Value::Array(
                (0..rng.below(2))
                    .map(|_| {
                        if depth < 2 {
                            random_ir(rng, depth + 1)
                        } else {
                            Value::Null
                        }
                    })
                    .collect(),
            ),
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
                let ir = if rng.chance(8) {
                    random_value(&mut rng, 0)
                } else {
                    random_ir(&mut rng, 0)
                };
                let _ = lineage_capable_aggregates(&ir);
                let _ = persistence_adapters(&ir);
                let _ = mirrored_aggregates(&ir);
                let _ = authorization_provider(&ir);
                let _ = membership_provider(&ir);
                let _ = identity_provider(&ir);
                let _ = command_declares(
                    &ir,
                    &random_text(&mut rng),
                    &random_text(&mut rng),
                    &random_text(&mut rng),
                );
                let _ = newsletter_provider(&ir).map(|p| p.instance_prefix());
                let _ = newsletter_issues_provider(&ir).map(|p| p.issue_prefix());
                let _ = payments_provider(&ir).map(|p| p.instance_prefix());
                let _ = checkout_windows(&ir);
                if let Some(p) = registrations_provider(&ir) {
                    let _ = (
                        p.event_prefix(),
                        p.registration_prefix(),
                        p.request_target(),
                    );
                }
                if let Some(p) = payment_connection_provider(&ir) {
                    let _ = p.instance_prefix();
                }
                let _ = registrations_binding(&random_text(&mut rng));
                let _ = payment_connection_binding(&random_text(&mut rng));
                if let Err(message) = refuse_unsupported_persistence_adapters(&ir) {
                    assert!(
                        message.contains("rust/host only has a backend")
                            || message.contains("does not declare")
                            || message.contains("rather than \"persistence\"")
                            || message.contains("\"adapters\""),
                        "seed {seed}: unhelpful refusal {message:?}"
                    );
                }
            }
        });
    }
}

fn ir_binding(adapter: &str, adapters: Option<Value>) -> Value {
    let mut ir =
        json!({"name": "D", "persistence": {"aggregates": [{"name": "A", "adapter": adapter}]}});
    if let Some(adapters) = adapters {
        ir["adapters"] = adapters;
    }
    ir
}

fn refusal(ir: &Value) -> String {
    refuse_unsupported_persistence_adapters(ir).unwrap_err()
}

#[test]
fn an_unsupported_persistence_adapter_is_always_refused_at_boot() {
    // No `adapters` key (every deployed IR today): the old behaviour, byte for byte.
    for adapter in ["Heki", "Memory", "Sqlite", "", "postgres", "Postgres "] {
        let message = refusal(&ir_binding(adapter, None));
        assert!(message.starts_with("rust/host only has a backend for [\"Postgres\", \"PostgresEra\"] today; this domain also binds: A (persisted_by "), "{adapter:?}");
    }
    for adapter in ["Postgres", "PostgresEra"] {
        assert!(refuse_unsupported_persistence_adapters(&ir_binding(adapter, None)).is_ok());
    }
}

#[test]
fn declared_supported_adapters_boot() {
    for adapter in ["Postgres", "PostgresEra"] {
        for port in [json!("persistence"), Value::Null] {
            let ir = ir_binding(
                adapter,
                Some(
                    json!([{"name": adapter, "port": port, "fields": [], "secrets": [], "defaults": {}}]),
                ),
            );
            assert!(
                refuse_unsupported_persistence_adapters(&ir).is_ok(),
                "{adapter} {port}"
            );
        }
    }
}

#[test]
fn declared_but_unsupported_adapters_hit_the_backend_rule() {
    for adapter in ["Heki", "Memory"] {
        let ir = ir_binding(
            adapter,
            Some(json!([{"name": adapter, "port": "persistence"}])),
        );
        assert!(
            refusal(&ir).starts_with("rust/host only has a backend"),
            "{adapter}"
        );
    }
}

#[test]
fn supported_but_undeclared_adapters_are_refused_by_name() {
    for declared in [json!([]), json!([{"name": "Heki", "port": "persistence"}])] {
        let message = refusal(&ir_binding("Postgres", Some(declared)));
        assert!(
            message.contains("A binds Postgres, which the domain's IR does not declare"),
            "{message}"
        );
    }
}

#[test]
fn a_non_persistence_port_is_refused() {
    for port in [json!("mail"), json!(""), json!(7), json!(["persistence"])] {
        let ir = ir_binding(
            "Postgres",
            Some(json!([{"name": "Postgres", "port": port}])),
        );
        assert!(
            refusal(&ir).contains("rather than \"persistence\""),
            "{port}"
        );
    }
}

#[test]
fn a_malformed_adapters_key_is_a_clear_refusal_never_a_panic() {
    for bad in [
        Value::Null,
        json!("Postgres"),
        json!(3),
        json!({"name": "Postgres"}),
        json!([{"port": "persistence"}]),
        json!([{"name": 5}]),
        json!([null]),
    ] {
        let message = refusal(&ir_binding("Postgres", Some(bad.clone())));
        assert!(message.contains("\"adapters\""), "{bad}: {message}");
    }
}
