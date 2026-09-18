require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_tick_fixture"

# `bin/qa_tick`, PROVEN AGAINST THE REAL THING — see `spec/qa_tick_dirty_
# tree_spec.rb`'s own header. One of four sibling files split out of the
# original `qa_tick_spec.rb` on 2026-09-18. Own throwaway database:
# `hecks_qa_tick_stale_hold_spec`.
RSpec.describe "bin/qa_tick", :io do
  include_context "with a qa_tick fixture", "hecks_qa_tick_stale_hold_spec"

  it "counts a stale hold the sweep reclaimed, so a recurring one is visible across ticks" do
    identify!("stale_one" => @target_domain_relpath)
    QualityControl::Target.find("stale_one").claim!(held_by: { value: "ghost" }, now: { value: Time.now.to_i - 5_000 })

    stdout, stderr, status = tick

    expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
    expect(stdout).to include("reclaimed stale hold: stale_one (held by ghost,", "stale holds reclaimed: 1 (stale_one)",
                              "tick: clean (exit 0)")
  end
end
