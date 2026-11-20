require "spec_helper"
require_relative "support/canary_helpers"

# A plant is sent to the reviewer naming no work item; the verdict is a catch, a miss or a mistake,
# tallied per canary and per tier.
RSpec.describe "the Agents canary verdict" do
  include CanaryHelpers

  before { boot_agents }

  it "asks the reviewer of a plant naming no work item" do
    plant("p1", "c1")
    review = Hecks::Agents::SubmissionReview.find("p1")
    expect([review.work&.value.to_s, review.repo.value]).to eq(["", "/tmp/p1"])
  end

  it "records a clean verdict on a plant as a miss, tallied on its canary" do
    add_canary("c1") && plant("p1", "c1")
    judge("p1", "clean")
    expect([outcome("p1"), canary("c1").misses.value]).to eq(%w[missed] + [1])
  end

  it "records the expected finding as a catch, tallied on its canary" do
    add_canary("c1") && plant("p1", "c1")
    judge("p1", "real_bug")
    expect([outcome("p1"), canary("c1").catches.value]).to eq(%w[caught] + [1])
  end

  it "records another finding as a mistake" do
    add_canary("c1") && plant("p1", "c1")
    judge("p1", "missing_behavior")
    expect(outcome("p1")).to eq("mistaken")
  end

  it "sets aside a plant whose commit is not of the full tier" do
    add_canary("c1") && plant("p1", "c1")
    judge("p1", "real_bug", tier: "verify_only")
    expect([outcome("p1"), canary("c1").unfit.value]).to eq(%w[unfit] + [1])
  end

  it "counts plants and catches per tier" do
    add_canary("c1") && [%w[p1 real_bug], %w[p2 clean]].each { |commit, word| plant(commit, "c1") && judge(commit, word) }
    expect(catches_by_tier).to eq([{ canary_plants: { "full" => 1 } }])
  end
end
