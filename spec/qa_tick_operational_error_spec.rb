require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `bin/qa_tick`, PROVEN AGAINST THE REAL THING — see `spec/qa_tick_dirty_
# tree_spec.rb`'s own header. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18. Own throwaway database:
# `hecks_qa_tick_operational_error_spec`.
RSpec.describe "bin/qa_tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_operational_error_spec"

  it "reports an operational error from the sweep as the tick's own exit 1" do
    identify!("broken_one" => "qa/stress_domains/__qa_tick_spec_does_not_exist__")

    stdout, _stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("bin/qa_pr_check:   clean (exit 0)",
                              "bin/qa_sweep --all: operational error (exit 1)",
                              "tick: operational error (exit 1)")
  end
end
