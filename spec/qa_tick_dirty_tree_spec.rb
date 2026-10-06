require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `hecks quality_control tick` run as a real subprocess against a disposable PostgresEra ledger and
# a throwaway repository with its own bare `origin`. Own database: `hecks_qa_tick_dirty_tree_spec`.
RSpec.describe "hecks quality_control tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_dirty_tree_spec"

  it "refuses a dirty tree before running anything", :aggregate_failures do
    File.write(File.join(@repo, "scratch.txt"), "uncommitted\n")

    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("refused: the working tree is dirty", "scratch.txt")
    expect(stdout).not_to include("── hecks quality_control check_pull_requests", "── hecks quality_control ask run --all")
  end
end
