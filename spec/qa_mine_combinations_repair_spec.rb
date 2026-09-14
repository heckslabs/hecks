require "spec_helper"
require_relative "support/qa_mine_combinations_helpers"

# `bin/qa_mine_combinations`' repair rounds — a candidate that does not
# boot goes back to the agent. Its own file for the shards; see
# spec/support/qa_mine_combinations_helpers.rb.
RSpec.describe "bin/qa_mine_combinations, repairing a candidate" do
  include QaMineCombinationsHelpers

  it "sends a candidate that does not boot back to the agent, and checks the repaired file" do
    out, status = run_miner("--candidates", "1", "--seeds", "1", "--steps", "4", mode: "repair")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("repair round 1: 1 candidate(s) did not boot")
    expect(out).to include("mined_desk: boots (repaired)")
  end

  it "reports a candidate still broken after the repair rounds as INVALID and exits 1 with nothing to check" do
    out, status = run_miner("--candidates", "1", "--repair-rounds", "0", mode: "repair")

    expect(status.exitstatus).to eq(1), out
    expect(out).to include("mined_desk: INVALID")
    expect(out).to include("no candidate booted")
  end
end
