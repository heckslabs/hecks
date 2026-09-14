require "spec_helper"
require_relative "support/qa_mine_combinations_helpers"

# `bin/qa_mine_combinations` handing a booting candidate to
# `bin/qa_generated_domains --source` — its own file because it is the
# slowest example of the miner's specs (~24s on a CI runner); see
# spec/support/qa_mine_combinations_helpers.rb.
RSpec.describe "bin/qa_mine_combinations, checking a candidate" do
  include QaMineCombinationsHelpers

  it "checks what the agent wrote through qa_generated_domains --source, and exits with its verdict" do
    out, status = run_miner("--candidates", "1", "--seeds", "1", "--steps", "4")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("mined_desk: boots")
    expect(out).to include("[source:mined_desk]: clean")
    expect(out).to include("generated domains: 1 clean, 0 found something")
  end
end
