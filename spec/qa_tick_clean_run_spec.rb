require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `bin/qa_tick`, PROVEN AGAINST THE REAL THING — see `spec/qa_tick_dirty_
# tree_spec.rb`'s own header. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18. Own throwaway database:
# `hecks_qa_tick_clean_run_spec`.
RSpec.describe "bin/qa_tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_clean_run_spec"

  it "rebases, runs the PR check FIRST and the sweep second, and is clean on an empty ledger" do
    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    pr_check_at = stdout.index("── bin/qa_pr_check")
    sweep_at    = stdout.index("── bin/qa_sweep --all")
    expect(pr_check_at).not_to be_nil
    expect(sweep_at).not_to be_nil
    expect(pr_check_at).to be < sweep_at
    generated_at = stdout.index("── bin/qa_generated_domains --from-dials")
    expect(generated_at).not_to be_nil
    expect(sweep_at).to be < generated_at
    expect(stdout).to include("generated domains: off (QualityControlDials::GENERATED_DOMAINS_PER_TICK is 0)",
                              "bin/qa_generated_domains: clean (exit 0)")
    expect(stdout).to include("── git fetch origin && git rebase origin/main",
                              "no PRs tracked as open", "rotation is empty",
                              "stale holds reclaimed: 0", "tick: clean (exit 0)")
  end
end
