//! Fixture binary with a deliberate rehydration bug, so the self-consistency spec can prove
//! its Rust-side checks fire. Given a "seed" it answers a value that never round-trips.
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");

    // Differs on every invocation, so seeding never reproduces prior state or itself.
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
