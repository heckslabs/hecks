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
// EVERY `pub mod` DECLARATION AND THE REGISTRY ITSELF are generated —
// `bin/ir_rust_registry > registry.rs`, held fresh by
// `spec/ir_rust_registry_export_spec.rb`. `include!` rather than a
// `mod registry;` : a bare `pub mod x;` only resolves against the FILE
// it's written in, and generating the whole of this file (including the
// integration tests below, which have nothing to do with which domains
// are registered) would mean folding real Rust test logic into a Ruby
// heredoc. `include!` splices the generated text here, before path
// resolution happens, so `registry.rs`'s own `pub mod banking;` resolves
// exactly as if it had been typed directly into this file.
//
// ALWAYS EVERY DOMAIN THAT'S BEEN PROJECTED — which ones actually compile
// into a given binary is a Cargo feature (`rust/Cargo.toml`'s own
// `[features]`), not a different generated file. `cargo build`/`cargo
// test` with no flags links `default` (all six, unchanged from before this
// was generated) ; `cargo build -p hecksagain-cli --no-default-features
// --features banking` links only Banking. `registry()`'s own doc comment
// explains why this is a function and not a `const` table.
include!("registry.rs");

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

    registry()
        .into_iter()
        .find(|projected| projected.chapter == name && projected.sha == digest)
        .map(|projected| (projected.domain)())
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
    registry()
        .into_iter()
        .find(|projected| projected.chapter == name)
        .map(|projected| (projected.domain)())
}

/// Every chapter THIS BUILD carries — feature-dependent, unlike everything
/// else in this file, which is the same regardless of which domains were
/// compiled in.
pub fn names() -> Vec<&'static str> {
    registry().iter().map(|projected| projected.chapter).collect()
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
        let chapters: Vec<(&str, super::super::ir::Domain)> = super::registry()
            .into_iter()
            .map(|projected| (projected.chapter, (projected.domain)()))
            .collect();

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

    /// THE POSTCONDITION, THROUGH THE COMPILED PATH SPECIFICALLY — not
    /// just carried as data (`every_projected_domain_says_what_ruby_says`
    /// already proves that) but actually EVALUATED by a dispatch that
    /// never read a byte of banking.bluebook. `Runtime::boot` and
    /// `boot_projected` converge on the same `dispatch`/`dispatch_entity`
    /// — enforce_ensures is not special-cased per boot path — so this is
    /// the same claim `ensures_test.rs` makes for the PARSED path, aimed
    /// at the projection instead. Debit's own postconditions
    /// (`old.balance.cents == balance.cents + amount.cents`, `balance.cents
    /// >= 0`) hold by construction for a correct debit, exactly like the
    /// Ruby dogfood in spec/runtime/command_rules_spec.rb — DbC's point is
    /// a postcondition that never fires in a correct run, so this proves
    /// the projected path evaluates it without wrongly refusing, which a
    /// subtle dispatch-order bug in the compiled path could still get
    /// wrong even with the data present.
    #[test]
    fn a_projected_domain_s_ensures_actually_evaluate() {
        let mut runtime = crate::dispatcher::Runtime::boot_projected("Banking")
            .expect("Banking is compiled into this binary");

        let mut register = serde_json::Map::new();
        register.insert("reference".into(), serde_json::json!({ "value": "c1" }));
        register.insert("name".into(), serde_json::json!({ "given": "A", "family": "Customer" }));
        register.insert("email".into(), serde_json::json!({ "address": "a@example.com" }));
        runtime
            .dispatch("Banking::Customer.Register", &register)
            .expect("Register never refuses here");

        let mut open = serde_json::Map::new();
        open.insert("customer_id".into(), serde_json::json!("c1"));
        open.insert("number".into(), serde_json::json!({ "value": "a1" }));
        open.insert("kind".into(), serde_json::json!({ "name": "current" }));
        open.insert("daily_limit".into(), serde_json::json!({ "cents": 50_000 }));
        runtime
            .dispatch("Banking::Account.Open", &open)
            .expect("Open never refuses here");

        let mut credit = serde_json::Map::new();
        credit.insert("number".into(), serde_json::json!({ "value": "a1" }));
        credit.insert("amount".into(), serde_json::json!({ "cents": 10_000, "currency": "USD" }));
        credit.insert("narrative".into(), serde_json::json!({ "text": "Opening" }));
        runtime
            .dispatch("Banking::Account.Credit", &credit)
            .expect("Credit never refuses here");

        let mut debit = serde_json::Map::new();
        debit.insert("number".into(), serde_json::json!({ "value": "a1" }));
        debit.insert("amount".into(), serde_json::json!({ "cents": 4_000 }));
        debit.insert("narrative".into(), serde_json::json!({ "text": "Withdrawal" }));

        let state = runtime
            .dispatch("Banking::Account.Debit", &debit)
            .expect("a holding postcondition, evaluated through the PROJECTED path, does not refuse");

        assert_eq!(
            state.get("balance").and_then(|balance| balance.get("cents")),
            Some(&serde_json::json!(6_000)),
            "the mutation Debit's own ensures checks — decremented by exactly the amount"
        );
    }

    /// AND REFUSES BY NAME when the binary does not carry the chapter, saying
    /// what it does carry rather than failing to find a file nobody named.
    ///
    /// AGAINST `registry()`, not a hardcoded chapter — this doubles as the
    /// concrete proof a feature-limited build carries only what it claims
    /// to: run under `--no-default-features --features banking` and the
    /// refusal names Banking and nothing else, because `names()` (which the
    /// refusal message itself lists) only ever reflects what THIS build
    /// actually registered.
    #[test]
    fn an_unprojected_chapter_says_what_is_carried() {
        let refusal = match crate::dispatcher::Runtime::boot_projected("Nowhere") {
            Err(why) => why,
            Ok(_) => panic!("a chapter this binary does not carry must refuse"),
        };
        assert!(refusal.contains("carries no projection"), "{refusal}");

        let carried = super::registry();
        assert!(!carried.is_empty(), "this build carries no projected domain at all — nothing to check");
        assert!(
            carried.iter().all(|projected| refusal.contains(projected.chapter)),
            "the refusal must name every chapter this build actually carries: {refusal}"
        );
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
