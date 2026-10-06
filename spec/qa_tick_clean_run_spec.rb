require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `hecks quality_control tick`, proven against the real thing — see `spec/qa_tick_dirty_
# tree_spec.rb`'s own header. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18. Own throwaway database:
# `hecks_qa_tick_clean_run_spec`.
RSpec.describe "hecks quality_control tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_clean_run_spec"

  # The steps of a tick, in the order they must run: the PR check first, the sweep second.
  TICK_STEP_ORDER = ["── hecks quality_control check_pull_requests", "── hecks quality_control ask run --all",
                     "── hecks quality_control check_generated_domains --from-dials"].freeze

  TICK_REPORT = ["generated domains: off (QualityControlDials::GENERATED_DOMAINS_PER_TICK is 0)",
                 "hecks quality_control check_generated_domains: clean (exit 0)",
                 "── git fetch origin && git rebase origin/main", "no PRs tracked as open", "rotation is empty",
                 "stale holds reclaimed: 0", "tick: clean (exit 0)"].freeze

  it "rebases, and runs the PR check FIRST and the sweep second", :aggregate_failures do
    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    positions = TICK_STEP_ORDER.map { |step| stdout.index(step) }
    expect(positions).to all(be_an(Integer))
    expect(positions.each_cons(2).all? { |earlier, later| earlier < later }).to be(true), positions.inspect
  end

  it "is clean on an empty ledger" do
    stdout, = tick

    expect(stdout).to include(*TICK_REPORT)
  end
end
