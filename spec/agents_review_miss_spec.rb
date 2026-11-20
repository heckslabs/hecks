require "spec_helper"
require_relative "support/review_miss_helpers"

# A clean verdict that a red main later contradicts is a review miss: Deliver's red episode reverts
# the landing of the same work item, and the miss keeps the verdict's tier, hops and evidence.
RSpec.describe "the Agents review miss" do
  include ReviewMissHelpers

  before { boot_agents }

  it "records a clean verdict whose work item's landing was reverted as a miss" do
    clean("c1", "w1")
    revert("ep1", "w1")
    expect(missed_commits).to eq(["c1"])
  end

  it "keeps the verdict's tier, hops and evidence on the miss" do
    clean("c1", "w1")
    revert("ep1", "w1")
    expect([miss("c1").tier.value, miss("c1").hops.value, miss("c1").evidence.map(&:run)]).to eq(["full", 1, ["c1-behaviors"]])
  end

  it "records no miss for a verdict that was not clean" do
    real_bug("c1", "w1")
    revert("ep1", "w1")
    expect(misses).to be_empty
  end

  it "records no miss for an episode of another work item" do
    clean("c1", "w1")
    revert("ep1", "w2")
    expect(misses).to be_empty
  end

  it "keeps the first episode when a redone work item is reverted again" do
    clean("c1", "w1")
    [%w[ep1 w1], %w[ep2 w1]].each { |episode, work| revert(episode, work) }
    expect(miss("c1").episode.value).to eq("ep1")
  end

  it "records each clean verdict of a redone work item once" do
    [%w[c1 ep1], %w[c2 ep2]].each { |commit, episode| clean(commit, "w1") && revert(episode, "w1") }
    expect(missed_commits).to eq(%w[c1 c2])
  end
end
