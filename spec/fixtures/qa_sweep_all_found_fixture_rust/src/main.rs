// THE ONE DELIBERATE, HAND-WRITTEN, PERMANENT MISMATCH `spec/qa_sweep_
// all_spec.rb`'s own "found something" example depends on — see this
// fixture's own `Cargo.toml` header and that spec's own comment on the
// found_one example for why this exists as a wholly separate, hand-
// maintained crate rather than a real generated domain.
//
// Reads (and discards) whatever `{"steps": [...]}` script `bin/qa_sweep`
// feeds it on stdin — same wire shape the real `rust::kernel::cli::run`
// reads — and always answers the SAME fixed JSON, naming a Beacon
// instance and a BeaconLit-shaped event with the sentinel id
// `__qa_sweep_all_spec_phantom__`. The real Ruby side
// (`qa_sweep_all_found_fixture.bluebook`) never mints that id under any
// generated sequence, at any seed, so `instances` and `events` diverge
// from the Ruby-side replay on literally every run, unconditionally —
// never a fact about whether the fuzzer happened to dispatch `Light`,
// and never a fact this fixture depends on any OTHER part of the
// codebase staying broken to keep proving.
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");
    let _ = input;

    println!(
        "{{\"instances\":{{\"QaSweepAllFoundFixture::Beacon#__qa_sweep_all_spec_phantom__\":{{\"reference\":{{\"value\":\"__qa_sweep_all_spec_phantom__\"}}}}}},\
\"events\":[{{\"name\":\"BeaconLit\",\"aggregate\":\"QaSweepAllFoundFixture::Beacon\",\"id\":\"__qa_sweep_all_spec_phantom__\",\"payload\":{{}}}}],\
\"refusals\":[],\"reactions\":[],\"cross_domain_reactions\":[],\"sagas\":[],\"queries\":[]}}"
    );
}
