require "spec_helper"
require_relative "support/red_episode_helpers"

# A red episode is the whole record of one stretch of red main: when it began, when it ended and
# how. Every time is passed in, since the bluebook reads no clock, and everything runs in Memory.
RSpec.describe "a red episode whose merge is reverted" do
  include_context "with red episodes in Memory"

  before { reverting("e1", at: 100) }

  it "ends reverted when the flag is lowered after the revert of a pushed merge", :aggregate_failures do
    landing_reverted("e1")
    flag_cleared(at: 160)
    expect(ended("e1")).to eq(["reverted", 100, 160])
    expect(held("e1", :revert)).to eq("r-e1")
  end

  it "ends reverted when a local revert is verified and the flag lowered" do
    landing_reverted("e1", local: true)
    flag_cleared(at: 130)
    expect(ended("e1")).to eq(["reverted", 100, 130])
  end

  it "records the revert on the episode the push train's revert is keyed by, and no other" do
    reverting("e2", at: 100)
    landing_reverted("e2")
    expect([held("e1", :revert), held("e2", :revert)]).to eq([nil, "r-e2"])
  end

  it "keeps the decision, the culprit, the branch and the Work item on the record" do
    landing_reverted("e1")
    flag_cleared(at: 160)
    expect(%i[status culprit branch work].map { |name| held("e1", name) }).to eq(%w[reverting m-e1 feature-e1 feature-e1])
  end
end
