require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` `dry_runs` comparison surface.
# Own throwaway database: `hecks_qa_sweep_all_dry_run_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_dry_run_spec"

  def run_dry_run_divergence
    identify_targets!("dry_run_one" => "spec/fixtures/qa_sweep_all_dry_run_fixture")
    run_qa_sweep("dry_run_one", "--seeds", "2", "--dry-run", "1", "--self-consistency", "false")
  end

  # `--dry-run 1` makes the Ruby side of `qa_sweep_all_dry_run_fixture` produce nothing, so the
  # sides differ on `dry_runs` alone; `--self-consistency false` isolates that one surface.
  it "finds a dry_runs-only divergence, exiting 2 on a surprised differential seed", :aggregate_failures do
    stdout, _stderr, status = run_dry_run_divergence

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("resolved modes: differential,properties_in_differential,structural_skip_report " \
                              "(capabilities=rust,sqlite)", "seed 1: SURPRISED (differential)")
  end

  it "names dry_runs as the one surface that diverged, with every other surface agreeing", :aggregate_failures do
    stdout, = run_dry_run_divergence

    expect(stdout).to include("subject:     [differential] qa_sweep_all_dry_run_fixture fuzz seed 1",
                              "observation: diverged on: dry_runs", "-- dry_runs --", "__qa_sweep_all_spec_phantom_dry_run__")
    expect(stdout).not_to include("-- instances --", "-- events --", "-- refusals --")
  end
end
