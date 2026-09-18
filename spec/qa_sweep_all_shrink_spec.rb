require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — SHRINKING. One of seven sibling files split out
# of the original `qa_sweep_all_spec.rb` (Phase 2 of the CI speed effort
# — see `spec/qa_sweep_all_lifecycle_spec.rb`'s own header and
# `spec/support/qa_sweep_all_fixture.rb` for the full context). Split
# again from `qa_sweep_all_report_and_parity_spec.rb` on 2026-09-18 — see
# `spec/qa_sweep_all_output_capture_spec.rb`'s own header for why. Own
# throwaway database: `hecks_qa_sweep_all_shrink_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_shrink_spec"

  # SHRUNK BEFORE REPORTED — `found_one`'s fixture binary answers a
  # phantom instance, event and no refusals for ANY script, so the
  # finding survives on a handful of steps (one refused dispatch and one
  # dry run are what keep the refusals/dry_runs parts of its signature)
  # out of the 25 generated; the file the report names holds exactly
  # the steps it printed.
  it "shrinks a differential finding before reporting it, and writes the replayable file" do
    identify_targets!("found_one" => "spec/fixtures/qa_sweep_all_found_fixture")

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "1", "--no-parity")

    expect(status.exitstatus).to eq(2)
    shrunk_to = stdout[/^shrunk:      \[differential\] 25 -> (\d+) step\(s\)/, 1]
    expect(shrunk_to.to_i).to be_between(1, 3)
    expect(stdout).to include("replay:      bin/rust_conformance", "-- shrunk steps [differential] --")
    shrunk_file = stdout[%r{^file:        (tmp/qa-shrunk/\S+-differential\.json)$}, 1]
    expect(JSON.parse(File.read(File.join(InMemoryDomain::ROOT, shrunk_file))).fetch("steps").size).to eq(shrunk_to.to_i)
  end
end
