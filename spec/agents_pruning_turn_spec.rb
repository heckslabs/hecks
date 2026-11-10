require "spec_helper"
require_relative "support/resting_pruner"

# One pruner at a time, and a new run key (minted by the reaction) for each.
RSpec.describe "the pruner's turn" do
  include_context "with a resting pruner"

  it "starts no second pruner while one is working" do
    launch("pruning.wake!", "to=pruner", "repo.value=#{scratch}", "brief.value=prune", "--wait")
    land("w-second")
    expect(pruners_started).to eq(1)
  end

  it "dispatches a pruner again once the first has ended, under a new run key" do
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    land("w-a")
    land("w-b")
    expect(pruners_started).to eq(2)
  end
end
