// Hand-written fixture crate for spec/qa_sweep_all_spec.rb's "found something" examples.
// The build feature selects one fixed answer; stdin is read but mostly ignored.
//
// `qa_sweep_all_found_fixture`: always answers one Beacon instance and event with a sentinel id
// the Ruby side never mints, so instances and events diverge on every run.
//
// `qa_sweep_all_dry_run_fixture`: every surface agrees with the Ruby side except `dry_runs`,
// which names a sentinel verb per `"dry_run":` step (counted by substring, no JSON parser).
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
