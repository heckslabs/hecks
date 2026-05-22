// rust/tests/vindiction_match_test.rs
//
// i9 observable repro : boot the real VinDiction domain + fixtures
// the SAME way the wasm worker does (parse aggregates, parse
// .fixtures, boot Runtime, seed via repo_lookup_key), then run
// Product.by_make_model. Prints every key surface so the empty-
// result bug is visible, not invisible-in-wasm. Becomes the
// regression test once green.
use std::collections::HashMap;
use storehouse::parser;
use storehouse::fixtures_parser;
use storehouse::runtime::{Runtime, AggregateState, Value, repo_lookup_key};

const V: &str = "/Users/christopheryoung/Projects/vindiction";

// IGNORED in automated runs : this is the i9 observable repro that
// reads bluebooks + fixtures from a HARDCODED local sibling repo
// (`/Users/christopheryoung/Projects/vindiction`) that is not checked
// out in CI. It panics with NotFound on any machine without that path.
// It was previously masked because Parity CI died at the miette
// sibling checkout before `cargo test` ran ; now that the miette
// checkout is optional, the cargo step runs and this local-only repro
// would fail. Kept as a manual repro (`cargo test -- --ignored`) on a
// machine that has the vindiction repo. Follow-up : parameterise the
// path via env or vendor a fixture so it can gate in CI.
#[ignore]
#[test]
fn vindiction_by_make_model_returns_products() {
    let prod = std::fs::read_to_string(format!("{V}/aggregates/product/product.bluebook")).unwrap();
    let veh  = std::fs::read_to_string(format!("{V}/aggregates/vehicle/vehicle.bluebook")).unwrap();
    let fixsrc = std::fs::read_to_string(format!("{V}/vindiction.fixtures")).unwrap();

    let mut domain = parser::parse(&prod);
    let vehd = parser::parse(&veh);
    domain.aggregates.extend(vehd.aggregates);
    let ff = fixtures_parser::parse(&fixsrc);
    domain.fixtures.extend(ff.fixtures);

    eprintln!("-- aggregates (name : context : identified_by) --");
    for a in &domain.aggregates {
        eprintln!("   {} : {:?} : {:?}", a.name, a.context, a.identified_by);
    }
    eprintln!("-- domain.fixtures : {} --", domain.fixtures.len());
    if let Some(f) = domain.fixtures.first() {
        eprintln!("   first: agg={} name={:?} attrs={}", f.aggregate_name, f.name, f.attributes.len());
    }

    let mut rt = Runtime::boot_with_data_dir(domain, None);
    eprintln!("-- repo keys at boot --");
    for k in rt.repositories.keys() { eprintln!("   {k}"); }

    // Replicate worker seed_fixtures exactly.
    let identified_by: HashMap<String, Option<String>> = rt.domain.aggregates.iter()
        .map(|a| (a.name.clone(), a.identified_by.clone())).collect();
    let fixtures = rt.domain.fixtures.clone();
    let mut seeded = 0usize; let mut skipped = 0usize;
    for fix in &fixtures {
        let Some(rk) = repo_lookup_key(&rt.repositories, &fix.aggregate_name) else { skipped += 1; continue };
        let idf = identified_by.get(&fix.aggregate_name).cloned().flatten();
        let id = if let Some(ref k) = idf {
            fix.attributes.iter().find(|(kk, _)| kk == k).map(|(_, v)| v.clone())
                .or_else(|| fix.name.clone()).unwrap_or_default()
        } else { fix.name.clone().unwrap_or_default() };
        let mut st = AggregateState::new(&id);
        for (k, v) in &fix.attributes { st.set(k, Value::Str(v.clone())); }
        if let Some(repo) = rt.repositories.get_mut(&rk) { repo.seed_record(st); seeded += 1; }
    }
    eprintln!("-- seeded={seeded} skipped={skipped} --");
    for (k, repo) in &rt.repositories { eprintln!("   repo {k} -> {} records", repo.all().len()); }

    let mut attrs = HashMap::new();
    attrs.insert("make".to_string(), "BMW".to_string());
    attrs.insert("model".to_string(), "6 Series".to_string());
    let r = rt.resolve_query_qualified(None, "Product", "by_make_model", &attrs);
    eprintln!("-- by_make_model(BMW,6 Series) --\n{}", serde_json::to_string(&r).unwrap().chars().take(400).collect::<String>());

    let n = r.get("state").and_then(|s| s.as_array()).map(|a| a.len()).unwrap_or(0);
    assert!(n > 0, "by_make_model returned {n} records — the i9 bug");
}
