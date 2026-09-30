require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `hecks quality_control tick`, proven against the real thing — see `spec/qa_tick_dirty_
# tree_spec.rb`'s own header. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18. Own throwaway database:
# `hecks_qa_tick_operational_error_spec`.
RSpec.describe "hecks quality_control tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_operational_error_spec"

  it "reports an operational error from the sweep as the tick's own exit 1" do
    identify!("broken_one" => "qa/stress_domains/__qa_tick_spec_does_not_exist__")

    stdout, _stderr, status = tick

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("hecks quality_control check_pull_requests:   clean (exit 0)",
                              "hecks quality_control ask run --all: operational error (exit 1)",
                              "tick: operational error (exit 1)")
  end
end
