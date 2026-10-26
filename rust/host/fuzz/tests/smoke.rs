//! Drives the same `check` the fuzz target does, from a seeded byte stream, on the stable toolchain.
//!
//! Needs the compiled kernel (`rust/dist/banking.wasm`, or `HECKS_FUZZ_WASM`). With `HECKS_FUZZ_PG`
//! set it also compares against Postgres. `HECKS_FUZZ_SMOKE` sets how many scripts run (default 64).

use arbitrary::{Arbitrary, Unstructured};
use rust_host_fuzz::equivalence;
use rust_host_fuzz::ops::Script;
use std::time::Instant;

/// xorshift64*: the seed is the whole reproduction.
fn bytes(seed: u64, len: usize) -> Vec<u8> {
    let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..len)
        .map(|_| {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            (state.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 56) as u8
        })
        .collect()
}

#[test]
fn generated_scripts_agree() {
    let count: u64 = std::env::var("HECKS_FUZZ_SMOKE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64);
    let started = Instant::now();
    let (mut steps, mut accepted, mut compared) = (0, 0, 0);
    for seed in 0..count {
        let data = bytes(seed, 1024);
        let script =
            Script::arbitrary(&mut Unstructured::new(&data)).expect("1 KiB decodes to a script");
        let summary = equivalence::check(&script);
        steps += summary.steps;
        accepted += summary.accepted;
        compared += usize::from(summary.compared);
    }
    let took = started.elapsed();
    eprintln!(
        "{count} scripts, {steps} steps ({accepted} accepted), {compared} compared with postgres, {took:?} ({:.1} scripts/s)",
        count as f64 / took.as_secs_f64()
    );
    assert!(
        accepted * 4 >= steps,
        "fewer than a quarter of the steps reach the domain: {accepted}/{steps}"
    );
}
