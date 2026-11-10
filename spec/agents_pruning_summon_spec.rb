require "spec_helper"
require_relative "support/resting_pruner"

# A manual summon seats and wakes the pruner in one command, since a later command line starts
# with no pruner seated.
RSpec.describe "summoning the pruner by hand" do
  include_context "with a resting pruner"

  def summon
    launch("agents", "pruning.summon!", "role.value=pruner", "repo.value=#{scratch}", "brief.value=sweep", "--wait")
  end

  def wake_again
    launch("agents", "pruning.wake!", "to=pruner", "repo.value=#{scratch}", "brief.value=again", "--wait")
  end

  it "starts one run from a pruner that was never seated" do
    summon
    expect(reactions("StartThePrunerWhenWoken").size).to eq(1)
  end

  it "refuses a second wake while the pruner works" do
    summon
    expect(wake_again.last).not_to eq(0)
  end
end
