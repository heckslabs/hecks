require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `bin/qa_tick`, PROVEN AGAINST THE REAL THING — a real subprocess that
# runs the REAL `bin/qa_pr_check` and the REAL `bin/qa_sweep --all` as
# its own subprocesses, against a disposable PostgresEra ledger
# (`spec/support/qa_ledger_fixture.rb`) and a throwaway git repository
# with its own bare `origin`. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18 (see `spec/support/
# qa_tick_fixture.rb`'s own header for why). Own throwaway database:
# `hecks_qa_tick_dirty_tree_spec`.
RSpec.describe "bin/qa_tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_dirty_tree_spec"

  it "refuses a dirty tree before running anything" do
    File.write(File.join(@repo, "scratch.txt"), "uncommitted\n")

    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("refused: the working tree is dirty", "scratch.txt")
    expect(stdout).not_to include("── bin/qa_pr_check", "── bin/qa_sweep --all")
  end
end
