// THE DELIBERATE, HAND-WRITTEN, PERMANENT MISMATCHES `spec/qa_sweep_
// all_spec.rb`'s own "found something" examples depend on — see this
// fixture's own `Cargo.toml` header and that spec's own comments on the
// found_one / dry_run_one examples for why these exist as one wholly
// separate, hand-maintained crate rather than real generated domains.
//
// TWO FEATURES, ONE BINARY PER BUILD — `RustConformanceHelpers#build_
// rust_for` builds `--features <domain basename>` and pins the result
// per feature, so `cfg!(feature = ...)` below is what selects which
// fixed answer this binary gives. Both read (and mostly discard)
// whatever `{"steps": [...]}` script `bin/qa_sweep` feeds them on stdin
// — the same wire shape the real `rust::kernel::cli::run` reads.
//
// `qa_sweep_all_found_fixture` — always answers the SAME fixed JSON,
// naming a Beacon instance and a BeaconLit-shaped event with the
// sentinel id `__qa_sweep_all_spec_phantom__`. The real Ruby side
// (`qa_sweep_all_found_fixture.bluebook`) never mints that id under any
// generated sequence, at any seed, so `instances` and `events` diverge
// from the Ruby-side replay on literally every run, unconditionally.
//
// `qa_sweep_all_dry_run_fixture` — the OPPOSITE shape: empty instances/
// events/refusals/queries (exactly what the Ruby side of
// `qa_sweep_all_dry_run_fixture.bluebook` produces when EVERY command
// step is a dry run, i.e. `bin/qa_sweep --dry-run 1`), plus one
// `dry_runs` entry per `"dry_run":` step in the script, each naming a
// sentinel verb (`__qa_sweep_all_spec_phantom_dry_run__`) the Ruby side
// never dispatches. Every surface but `dry_runs` AGREES, so a finding
// here proves that one comparison finds something on its own — counted
// by substring so this crate stays dependency-free (no JSON parser),
// which is enough: the Ruby side's `dry_runs` list has exactly one entry
// per `"dry_run":` step too, so the two lists differ on verb, never on
// length.
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");

    if cfg!(feature = "qa_sweep_all_dry_run_fixture") {
        let count = input.matches("\"dry_run\":").count();
        let entries: Vec<String> = (0..count)
            .map(|_| "{\"verb\":\"__qa_sweep_all_spec_phantom_dry_run__\",\"ok\":true}".to_string())
            .collect();
        println!(
            "{{\"instances\":{{}},\"events\":[],\"refusals\":[],\"reactions\":[],\"cross_domain_reactions\":[],\
             \"sagas\":[],\"queries\":[],\"dry_runs\":[{}]}}",
            entries.join(",")
        );
        return;
    }

    let _ = input;
    println!(
        "{{\"instances\":{{\"QaSweepAllFoundFixture::Beacon#__qa_sweep_all_spec_phantom__\":{{\"reference\":{{\"value\":\"__qa_sweep_all_spec_phantom__\"}}}}}},\
\"events\":[{{\"name\":\"BeaconLit\",\"aggregate\":\"QaSweepAllFoundFixture::Beacon\",\"id\":\"__qa_sweep_all_spec_phantom__\",\"payload\":{{}}}}],\
\"refusals\":[],\"reactions\":[],\"cross_domain_reactions\":[],\"sagas\":[],\"queries\":[],\"dry_runs\":[]}}"
    );
}
