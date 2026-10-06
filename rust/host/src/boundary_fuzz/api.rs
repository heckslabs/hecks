//! Seeded fuzz of the `/api` request-shaping helpers that run on caller-controlled input before
//! anything reaches the database: body parsing, identity minting, preconditions, sorting and
//! query-argument shaping. Each must refuse bad input with a structured answer, never panic, and
//! leave the arguments it was given untouched when it refuses.

use super::*;
use crate::fuzz_support::*;

fn envelope_is_structured(response: &Value) {
    let status = response["statusCode"].as_u64().expect("a refusal carries its status");
    assert!((400..600).contains(&status), "a refusal is a 4xx/5xx, got {status}");
    assert_eq!(response["headers"]["content-type"], "application/json");
    let body: Value = serde_json::from_str(response["body"].as_str().expect("a JSON body")).expect("the body is JSON");
    assert!(body["error"].is_string() && body["message"].is_string(), "the refusal names itself: {body}");
}

fn client_aggregate() -> Value {
    json!({
        "name": "Client",
        "identified_by": ["reference.value"],
        "attributes": [
            {"name": "reference", "type": "ClientReference", "list": false, "optional": false},
            {"name": "name", "type": "ClientName", "list": false, "optional": false},
            {"name": "owner", "type": "Reference<Member>", "list": false, "optional": true},
            {"name": "status", "type": "String", "list": false, "optional": true}
        ],
        "value_objects": [
            {"name": "ClientReference", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
            {"name": "ClientName", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []}
        ],
        "entities": [], "commands": [], "queries": [], "lifecycle": {"field": "status"}
    })
}

#[test]
fn parsed_body_refuses_everything_that_is_not_an_object_with_a_structured_400() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..50 {
                let text = match rng.below(4) {
                    0 => random_text(&mut rng),
                    1 => {
                        let valid = random_value(&mut rng, 0).to_string();
                        mutate_text(&mut rng, &valid)
                    }
                    2 => random_value(&mut rng, 0).to_string(),
                    _ => format!("{}{}", " \t\n".repeat(rng.below(3)), random_value(&mut rng, 1)),
                };
                match parsed_body(&text) {
                    Ok(body) => {
                        assert!(body.is_object(), "seed {seed}: {text:?} parsed to a non-object");
                        assert!(text.trim().is_empty() || serde_json::from_str::<Value>(&text).is_ok(), "seed {seed}: {text:?} is not JSON yet was accepted");
                    }
                    Err(refusal) => {
                        assert_eq!(refusal["statusCode"], 400, "seed {seed}: {text:?}");
                        envelope_is_structured(&refusal);
                    }
                }
            }
        });
    }
}

#[test]
fn parsed_body_survives_depth_width_and_size() {
    guarded("depth and size", || {
        for text in [
            "[".repeat(1_000_000),
            format!("{}1{}", "[".repeat(100_000), "]".repeat(100_000)),
            format!("{}1{}", "{\"a\":".repeat(100_000), "}".repeat(100_000)),
            format!("[{}]", vec!["1"; 500_000].join(",")),
            format!("{{\"a\":\"{}\"}}", "x".repeat(16 * 1024 * 1024)),
        ] {
            let _ = parsed_body(&text);
        }
        for text in ["[]", "1", "\"s\"", "null", "true", "{", "{\"a\":1}{}", "{} {}", "\u{feff}{}", "{\"a\":NaN}", "{\"a\":1e999}"] {
            if let Err(refusal) = parsed_body(text) {
                assert_eq!(refusal["statusCode"], 400, "{text:?}");
            }
        }
        assert_eq!(parsed_body("   ").unwrap(), json!({}));
        assert!(parsed_body("{\"a\":1,\"a\":2}").unwrap().is_object());
    });
}

#[test]
fn slugify_always_answers_a_clean_non_empty_slug() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..100 {
                let text = random_text(&mut rng);
                let slug = slugify(&text);
                assert!(!slug.is_empty(), "seed {seed}: {text:?} slugged to nothing");
                assert!(slug.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'), "seed {seed}: {text:?} -> {slug:?}");
                assert!(!slug.starts_with('-') && !slug.ends_with('-') && !slug.contains("--"), "seed {seed}: {text:?} -> {slug:?}");
            }
        });
    }
}

#[test]
fn identity_minting_survives_any_rule_and_leaves_args_alone_when_it_refuses() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x1D);
            let aggregate = client_aggregate();
            for _ in 0..50 {
                let mut rule = serde_json::Map::new();
                for key in ["field", "strategy", "source", "prefix", "pad"] {
                    if rng.chance(5) {
                        continue;
                    }
                    let value = match key {
                        "field" if rng.chance(2) => json!(*rng.pick(&["reference", "name", "owner", "status", "missing", ""])),
                        "strategy" if rng.chance(2) => json!(*rng.pick(&["slug", "sequence", "port", "nope", ""])),
                        "source" if rng.chance(2) => json!(*rng.pick(&["name", "reference", "owner", "missing", ""])),
                        "pad" if rng.chance(2) => json!(*rng.pick(&[0u64, 1, 3, 64, 65, 1_000, 1_000_000, 1u64 << 40, 1u64 << 62, u64::MAX])),
                        _ => random_value(&mut rng, 2),
                    };
                    rule.insert(key.to_string(), value);
                }
                let presentation = json!({"collections": {"Client": {"identity": Value::Object(rule)}}});
                let mut args = random_value(&mut rng, 0);
                if rng.chance(2) {
                    args = json!({"name": random_value(&mut rng, 2)});
                }
                let before = args.clone();
                let existing = *rng.pick(&[0usize, 1, 41, 999_999, usize::MAX - 1]);
                match apply_identity(&presentation, &aggregate, &mut args, existing) {
                    Ok(()) => {}
                    Err(refusal) => {
                        envelope_is_structured(&refusal);
                        assert_eq!(args, before, "seed {seed}: a refused identity must not have touched the args");
                    }
                }
            }
        });
    }
}

#[test]
fn an_absurd_sequence_pad_is_refused_rather_than_allocating_it() {
    let aggregate = client_aggregate();
    for pad in [65u64, 1_000_000, 1 << 40, u64::MAX] {
        let presentation = json!({"collections": {"Client": {"identity": {"field": "reference", "strategy": "sequence", "prefix": "C-", "pad": pad}}}});
        let mut args = json!({"name": {"value": "Acme"}});
        let refusal = apply_identity(&presentation, &aggregate, &mut args, 1).expect_err("a pad this wide is refused");
        envelope_is_structured(&refusal);
        assert_eq!(args, json!({"name": {"value": "Acme"}}), "pad {pad}: nothing was minted");
    }
    let presentation = json!({"collections": {"Client": {"identity": {"field": "reference", "strategy": "sequence", "prefix": "C-", "pad": 64}}}});
    let mut args = json!({});
    apply_identity(&presentation, &aggregate, &mut args, 0).expect("the widest allowed pad still mints");
    assert_eq!(args["reference"]["value"].as_str().unwrap().len(), 2 + 64);
}

#[test]
fn preconditions_survive_any_config_and_instances_shape() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xC0);
            for _ in 0..50 {
                let domain = json!({"name": random_text(&mut rng), "aggregates": [client_aggregate(), {"name": "Member", "lifecycle": random_value(&mut rng, 2)}]});
                let aggregate = client_aggregate();
                let rule = if rng.chance(3) {
                    random_value(&mut rng, 0)
                } else {
                    json!({"field": *rng.pick(&["owner", "name", "status", "missing"]), "state": random_value(&mut rng, 2), "message": random_value(&mut rng, 2)})
                };
                let args = if rng.chance(3) { random_value(&mut rng, 0) } else { json!({"owner": random_value(&mut rng, 2)}) };
                let instances = if rng.chance(3) { random_value(&mut rng, 0) } else { json!({format!("{}::Member#m1", domain_name(&domain)): random_value(&mut rng, 2)}) };
                if let Err(refusal) = check_precondition(&domain, &aggregate, &rule, &args, &instances) {
                    envelope_is_structured(&refusal);
                }
            }
        });
    }
}

#[test]
fn sorting_records_of_mixed_types_never_panics_on_an_inconsistent_order() {
    // `sort_by` may panic when its comparator is not a total order, so a column holding numbers,
    // empty strings, strings, nulls and objects together must still order consistently.
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x50);
            for _ in 0..10 {
                let mut records: Vec<(String, Value)> = (0..20 + rng.below(200))
                    .map(|i| {
                        let cell = match rng.below(8) {
                            0 => json!(rng.below(5)),
                            1 => json!(rng.below(5) as f64 / 2.0),
                            2 => json!(""),
                            3 => json!(*rng.pick(&["a", "b", "B", "10", "9", "é", "🍕"])),
                            4 => Value::Null,
                            5 => json!({"cents": rng.below(50)}),
                            6 => json!({"value": random_text(&mut rng)}),
                            _ => random_value(&mut rng, 2),
                        };
                        (format!("id{}", i % 17), json!({"col": cell}))
                    })
                    .collect();
                for descending in [false, true] {
                    let spec = Some(SortSpec { field: "col".to_string(), descending });
                    sort_records(&mut records, &spec);
                    sort_records(&mut records, &None);
                }
            }
        });
    }
}

#[test]
fn query_arguments_and_sort_params_survive_hostile_input() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x9A);
            let aggregate = client_aggregate();
            let domain = json!({"name": "Crm", "aggregates": [aggregate.clone()]});
            for _ in 0..30 {
                let named = if rng.chance(3) {
                    random_value(&mut rng, 0)
                } else {
                    json!({"attributes": [
                        {"name": *rng.pick(&["name", "owner", "reference", "x"]), "type": *rng.pick(&["ClientName", "String", "Reference<Member>", "Nope", "Integer"]), "optional": rng.chance(2)},
                        random_value(&mut rng, 2)
                    ]})
                };
                let mut params: HashMap<String, String> = HashMap::new();
                for _ in 0..rng.below(5) {
                    params.insert(random_text(&mut rng), random_text(&mut rng));
                }
                params.insert("name".to_string(), random_text(&mut rng));
                let _ = query_args_from_params(&aggregate, &named, &params);

                let sort: HashMap<String, String> = [("sort", random_text(&mut rng)), ("direction", random_text(&mut rng))].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
                let config = random_value(&mut rng, 0);
                let _ = resolve_sort(&domain, &config, "Client", &aggregate, &sort);
                let _ = resolve_sort(&domain, &json!({}), "Client", &aggregate, &HashMap::from([("sort".to_string(), "__state__".to_string())]));
            }
        });
    }
}

#[test]
fn identity_sources_and_scalars_render_any_json_value() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x5C);
            for _ in 0..50 {
                let args = json!({"name": random_value(&mut rng, 0)});
                let _ = dig_source(&args, "name");
                let _ = dig_source(&random_value(&mut rng, 0), &random_text(&mut rng));
                let _ = scalar_to_string(&random_value(&mut rng, 0));
            }
        });
    }
}
