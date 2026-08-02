// DOMAINS PROJECTED INTO RUST, one file each, by `bin/ir_rust`.
//
// `ir_structs.rs` projects the SHAPES the language declares; this projects
// VALUES of them. A domain here is not parsed at boot and did not come from
// Ruby at run time — it is the domain, compiled.
//
// Checked in for the same reason the other projections are: Rust cannot run the
// Ruby DSL, so it compiles against a copy, and a copy nothing compares is a copy
// that drifts. `spec/ir_rust_export_spec.rb` holds each file to its generator
// AND flattens what it returns back through `ir_json::domain_to_value` to diff
// against Ruby's own `to_h`.
pub mod banking;
pub mod expression;
pub mod market;
pub mod pizzas;
// REFLEX JOINED THE OTHERS once `Query`/`ReadModel` grew the eight
// specification options — offset, cursor, nulls, consistency, freshness,
// authorize, inspect_query, use_index. It used to be the one chapter this
// module could not carry: it declares every option the language holds, and
// projecting it would have had nowhere to put them. It still sits outside the
// zero-infrastructure parity corpus (`spec/parity/domains/`) — that was never
// about the options, and staying there is unrelated to this module.
pub mod reflex;
pub mod relay;
pub mod till_room;
pub mod wire;

/// THE PROJECTED DOMAIN FOR A SOURCE, if this binary carries its projection.
///
/// SEALED TO THE SOURCE, not merely named after it. Keyed on the chapter name
/// alone, a projection answers for any bluebook that calls itself the same
/// thing — a test fixture named `Banking` silently got the real banking — and
/// it keeps answering after its own source is edited, booting a stale domain
/// while every file on disk says otherwise. Both are the same mistake: a
/// projection is a specialization OF A PARTICULAR SOURCE, and a lookup that
/// does not say so is a lookup that can be wrong without anyone noticing.
///
/// So the digest decides. A hit means this binary holds the projection of
/// exactly these bytes, checked against Ruby's own IR when it was generated. A
/// miss — different chapter, edited source, no projection at all — parses,
/// which is always correct and merely slower.
pub fn by_source(source: &str) -> Option<crate::ir::Domain> {
    let name = chapter_name(source)?;
    let digest = crate::util::sha256_hex(source.as_bytes());

    let (sha, domain): (&str, fn() -> crate::ir::Domain) = match name.as_str() {
        "Banking" => (banking::SOURCE_SHA, banking::domain),
        "Expression" => (expression::SOURCE_SHA, expression::domain),
        "Market" => (market::SOURCE_SHA, market::domain),
        "Pizzas" => (pizzas::SOURCE_SHA, pizzas::domain),
        "Reflex" => (reflex::SOURCE_SHA, reflex::domain),
        "Relay" => (relay::SOURCE_SHA, relay::domain),
        "TillRoom" => (till_room::SOURCE_SHA, till_room::domain),
        "Wire" => (wire::SOURCE_SHA, wire::domain),
        _ => return None,
    };

    (sha == digest).then(domain)
}

/// A PROJECTED DOMAIN BY NAME, for a caller that holds no source at all.
///
/// `by_source` is the boot path's question — "is this the projection of the
/// bytes I am booting?" — and it needs the bytes. This is the other question:
/// "does this binary carry a chapter called X?", asked by a host that never had
/// a file. Nothing on disk is consulted, so nothing on disk has to exist.
///
/// The seal does not apply because there is no source to seal against: a caller
/// here is ASKING for the compiled-in domain rather than being handed one in
/// place of what they asked for. That is the whole difference, and it is why
/// these are two functions and not one with a flag.
pub fn by_name(name: &str) -> Option<crate::ir::Domain> {
    match name {
        "Banking" => Some(banking::domain()),
        "Expression" => Some(expression::domain()),
        "Market" => Some(market::domain()),
        "Pizzas" => Some(pizzas::domain()),
        "Reflex" => Some(reflex::domain()),
        "Relay" => Some(relay::domain()),
        "TillRoom" => Some(till_room::domain()),
        "Wire" => Some(wire::domain()),
        _ => None,
    }
}

/// Every chapter this binary carries, in the order they are declared above.
pub fn names() -> Vec<&'static str> {
    vec!["Banking", "Expression", "Market", "Pizzas", "Reflex", "Relay", "TillRoom", "Wire"]
}

/// THE CHAPTER A SOURCE DECLARES, without parsing it.
///
/// `Hecks.bluebook "Pizzas" do` — the first quoted string on the first
/// `Hecks.bluebook` line. Enough to look a projection up, and deliberately not
/// enough to be a second parser: a source this cannot read simply misses, and
/// misses parse.
pub fn chapter_name(source: &str) -> Option<String> {
    source.lines().find_map(|line| {
        let line = line.trim_start();
        if !line.starts_with("Hecks.bluebook") {
            return None;
        }
        let after = line.split_once('"')?.1;
        after.split_once('"').map(|(name, _)| name.to_string())
    })
}

#[cfg(test)]
mod tests {
    /// EVERY PROJECTED DOMAIN IS HELD TO RUBY, not merely to itself.
    ///
    /// `spec/golden/ir/*.json` is Ruby's own `to_h`, frozen. This flattens each
    /// PROJECTED domain back through the same wire projector `--dump` uses and
    /// diffs the two. The claim is not "the generator is deterministic" — it is
    /// "a domain compiled into Rust says exactly what Ruby says it is", which is
    /// `bin/parity`'s contract pointed at the projection.
    ///
    /// EVERY CHAPTER IN THE TREE, and that is the point of it. Pizzas alone
    /// exercised mutations, an append, invariants, a closed set and a lifecycle
    /// — and none of the paths that carry entities, sagas, dispatch bindings or
    /// read models. A generator whose rare branches nothing runs is the shape
    /// every defect this arc found had.
    #[test]
    fn every_projected_domain_says_what_ruby_says() {
        let chapters: Vec<(&str, super::super::ir::Domain)> = vec![
            ("Banking", super::banking::domain()),
            ("Expression", super::expression::domain()),
            ("Market", super::market::domain()),
            ("Pizzas", super::pizzas::domain()),
            ("Reflex", super::reflex::domain()),
            ("Relay", super::relay::domain()),
            ("TillRoom", super::till_room::domain()),
            ("Wire", super::wire::domain()),
        ];

        for (name, domain) in chapters {
            let golden = std::fs::read_to_string(
                std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join(format!("../spec/golden/ir/{name}.json")),
            )
            .unwrap_or_else(|_| panic!("spec/golden/ir/{name}.json — Ruby's frozen IR"));

            let ruby: serde_json::Value = serde_json::from_str(&golden).expect("the golden is JSON");
            let projected = crate::projector::ir_json::domain_to_value(&domain);
            let mine = projected
                .get(name)
                .unwrap_or_else(|| panic!("domain_to_value keys the body by chapter name"));

            if let Some(path) = first_difference(mine, &ruby, name) {
                panic!("the projected {name} differs from Ruby's frozen IR at {path}");
            }
        }
    }

    /// A DOMAIN THAT DISPATCHES WITH NOTHING ON DISK.
    ///
    /// The point of compiling a domain in, and the thing `boot` could not do:
    /// no path, no `.bluebook`, no world, no directory walked. If this ever
    /// needs a file to pass, the asterisk is back.
    #[test]
    fn a_projected_domain_dispatches_without_a_file() {
        let mut runtime = match crate::dispatcher::Runtime::boot_projected("Pizzas") {
            Ok(runtime) => runtime,
            Err(why) => panic!("Pizzas is compiled into this binary: {why}"),
        };

        let mut args = serde_json::Map::new();
        args.insert("name".into(), serde_json::json!({ "value": "Margherita" }));
        args.insert("price_cents".into(), serde_json::json!({ "cents": 1200 }));
        args.insert("size".into(), serde_json::json!({ "value": "large" }));

        let state = runtime
            .dispatch("Pizzas::Pizza.CreatePizza", &args)
            .expect("a compiled-in domain dispatches");

        assert_eq!(state.get("status"), Some(&serde_json::json!("available")),
                   "the lifecycle default came from the projection");
        assert_eq!(runtime.events.len(), 1, "PizzaCreated was announced");
    }

    /// AND REFUSES BY NAME when the binary does not carry the chapter, saying
    /// what it does carry rather than failing to find a file nobody named.
    #[test]
    fn an_unprojected_chapter_says_what_is_carried() {
        let refusal = match crate::dispatcher::Runtime::boot_projected("Nowhere") {
            Err(why) => why,
            Ok(_) => panic!("a chapter this binary does not carry must refuse"),
        };
        assert!(refusal.contains("carries no projection"), "{refusal}");
        assert!(refusal.contains("Pizzas"), "it names what it does hold: {refusal}");
    }

    /// WHERE THEY DIFFER, not that they differ. `assert_eq!` on a chapter is
    /// three thousand lines of JSON against three thousand lines of JSON, which
    /// reports the fact and hides the cause. This walks to the first divergence
    /// and names its path.
    fn first_difference(
        mine: &serde_json::Value,
        ruby: &serde_json::Value,
        path: &str,
    ) -> Option<String> {
        use serde_json::Value;
        match (mine, ruby) {
            (Value::Object(left), Value::Object(right)) => {
                for key in left.keys().chain(right.keys()) {
                    let here = format!("{path}.{key}");
                    match (left.get(key), right.get(key)) {
                        (Some(a), Some(b)) => {
                            if let Some(found) = first_difference(a, b, &here) {
                                return Some(found);
                            }
                        }
                        (None, Some(b)) => return Some(format!("{here} — missing, Ruby has {b}")),
                        (Some(a), None) => return Some(format!("{here} — extra, projected {a}")),
                        (None, None) => {}
                    }
                }
                None
            }
            (Value::Array(left), Value::Array(right)) => {
                if left.len() != right.len() {
                    return Some(format!("{path} — {} entries, Ruby has {}", left.len(), right.len()));
                }
                left.iter()
                    .zip(right)
                    .enumerate()
                    .find_map(|(i, (a, b))| first_difference(a, b, &format!("{path}[{i}]")))
            }
            _ if mine == ruby => None,
            _ => Some(format!("{path} — projected {mine}, Ruby has {ruby}")),
        }
    }
}
