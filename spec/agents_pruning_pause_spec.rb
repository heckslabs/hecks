require "spec_helper"
require_relative "support/resting_pruner"

# The owner's switch: a paused pruner is woken by nothing, seated or not, until it is resumed.
RSpec.describe "pausing the pruner" do
  include_context "with a resting pruner"

  def pruning(verb, *fields) = launch("agents", "pruning.#{verb}!", *fields, "--wait")

  def summon = pruning("summon", "role.value=pruner", "repo.value=#{scratch}", "brief.value=prune")

  def wake = pruning("wake", "to=pruner", "repo.value=#{scratch}", "brief.value=prune")

  def seat = launch!("agents", "pruning.seat!", "role.value=pruner", "--wait")

  def standing = JSON.parse(pruning("resume", "to=pruner").first).dig("state", "status")

  it "refuses a wake by the paused status", :aggregate_failures do
    seat
    pruning("pause", "to=pruner")
    expect(wake.first).to include("paused")
    expect(pruners_started).to eq(0)
  end

  it "refuses a summon while paused", :aggregate_failures do
    seat
    pruning("pause", "to=pruner")
    expect(summon.last).not_to eq(0)
    expect(pruners_started).to eq(0)
  end

  it "holds a pruner that was never seated, so a summon starts none", :aggregate_failures do
    expect(pruning("hold", "role.value=pruner").first).to include("\"status\": \"paused\"")
    summon
    expect(wake.first).to include("paused")
    expect(pruners_started).to eq(0)
  end

  it "wakes again once resumed", :aggregate_failures do
    pruning("hold", "role.value=pruner")
    expect(standing).to eq("resting")
    wake
    expect(pruners_started).to eq(1)
  end

  it "stays paused when the run it was paused under ends", :aggregate_failures do
    summon
    pruning("pause", "to=pruner")
    expect(pruning("rest", "to=pruner").first).to include("paused")
    expect(wake.last).not_to eq(0)
  end
end
