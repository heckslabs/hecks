// THE ONE DELIBERATE, HAND-WRITTEN, PERMANENT REHYDRATION BUG `spec/
// fuzzing/self_consistency_rust_spec.rb`'s own "the Rust-side checks can
// actually fire" proof depends on — see this fixture's own `Cargo.toml`
// header for why it exists as a wholly separate, hand-maintained crate
// rather than a real generated domain.
//
// Reads (and mostly ignores) whatever `{"steps": [...], "seed": ...}`
// `kernel::cli::run`-shaped input `bin/qa_sweep`/`Hecks::Fuzzing::
// SelfConsistency.rust_seed_round_trip` feeds it on stdin. A REAL
// `Store::from_seed`/`Store::instances` pair would echo a seeded
// `"instances"` value straight back out unchanged (that IS the whole
// contract `check_rust_rehydration`/`check_rust_idempotency` test) —
// this fixture answers a PROCESS-INVOCATION-DEPENDENT value instead,
// whenever it is given a `"seed"` at all, so:
//   - seeding it with ANY prior "live" instances never reproduces that
//     state (`check_rust_rehydration` fires), and
//   - seeding it twice in a row never even reproduces ITSELF
//     (`check_rust_idempotency` fires too) — each invocation is a fresh
//     OS process with no memory of the last one, so the drift value
//     genuinely differs call to call.
// A plain `{"steps": [...]}` ask with no `"seed"` at all answers a FIXED,
// well-behaved `"instances"` value — the "live" state a first, ordinary
// dispatch would have produced, before anyone ever asks this binary to
// rehydrate from it.
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");

    let drift: i64 = if input.contains("\"seed\"") {
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos() as i64
    } else {
        0
    };

    println!(
        "{{\"instances\":{{\"SelfConsistencyRustFixture::Thing#__fixture__\":{{\"drift\":{{\"value\":{drift}}}}}}},\
\"events\":[],\"refusals\":[],\"reactions\":[],\"cross_domain_reactions\":[],\"sagas\":[],\"queries\":[]}}"
    );
}
