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
// REFLEX IS NOT HERE, and the reason is its own bluebook's: it declares every
// QUERY OPTION the language holds — authorize, offset, cursor, nulls,
// consistency, freshness, inspect_query, use_index — and Rust's `Query` struct
// carries none of them. There is nowhere to project them TO. That chapter is
// deliberately outside the parity corpus for the same reason, and a projection
// that dropped the options silently would claim an agreement Rust cannot make.
pub mod pizzas;
pub mod relay;
pub mod till_room;
pub mod wire;

/// THE PROJECTED DOMAIN FOR A CHAPTER, if one was compiled in.
///
/// `Runtime::boot` asks this before it parses. A hit means the domain arrives as
/// Rust values that were checked against Ruby's own IR at build time, so nothing
/// is read out of the source at all — which also means `strict_boot`'s scan is
/// moot for that chapter: it exists because Rust's PARSER silently drops
/// constructs it cannot read, and a projection drops nothing.
///
/// A miss parses, exactly as before. Projecting a domain is an optimisation of
/// trust, not a requirement: an unprojected chapter still boots.
pub fn by_name(name: &str) -> Option<crate::ir::Domain> {
    match name {
        "Banking" => Some(banking::domain()),
        "Expression" => Some(expression::domain()),
        "Market" => Some(market::domain()),
        "Pizzas" => Some(pizzas::domain()),
        "Relay" => Some(relay::domain()),
        "TillRoom" => Some(till_room::domain()),
        "Wire" => Some(wire::domain()),
        _ => None,
    }
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
