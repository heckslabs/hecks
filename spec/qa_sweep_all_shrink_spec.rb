require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all`: shrinking.
# Own throwaway database: `hecks_qa_sweep_all_shrink_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_shrink_spec"

  # `found_one`'s fixture binary answers the same phantom result for any script, so the finding
  # survives on a few of the 25 steps; the named file must hold exactly the steps printed.
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
