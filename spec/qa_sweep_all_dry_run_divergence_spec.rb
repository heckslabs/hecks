require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` `dry_runs` comparison surface.
# Own throwaway database: `hecks_qa_sweep_all_dry_run_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_dry_run_spec"

  # `--dry-run 1` makes the Ruby side of `qa_sweep_all_dry_run_fixture` produce nothing, so the
  # sides differ on `dry_runs` alone; `--self-consistency false` isolates that one surface.
  it "finds a dry_runs-only divergence, with every other surface agreeing" do
    identify_targets!("dry_run_one" => "spec/fixtures/qa_sweep_all_dry_run_fixture")

    stdout, _stderr, status = run_qa_sweep("dry_run_one", "--seeds", "2", "--dry-run", "1", "--self-consistency", "false")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("resolved modes: differential,properties_in_differential,structural_skip_report " \
                              "(capabilities=rust,sqlite)")
    expect(stdout).to include("seed 1: SURPRISED (differential)")
    expect(stdout).to include("subject:     [differential] qa_sweep_all_dry_run_fixture fuzz seed 1")
    expect(stdout).to include("observation: diverged on: dry_runs", "-- dry_runs --")
    expect(stdout).not_to include("-- instances --", "-- events --", "-- refusals --")
    expect(stdout).to include("__qa_sweep_all_spec_phantom_dry_run__")
  end
end
