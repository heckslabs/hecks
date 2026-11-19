require "spec_helper"
require_relative "support/epic_charter_helpers"

# A tier the owner set by hand is left alone by the product owner while its hold lasts.
RSpec.describe "the owner's hold on an epic's tier" do
  include EpicCharterHelpers

  before { epic }

  it "refuses the product owner's rank inside the hold", :aggregate_failures do
    rank(2, "now.value=1000")
    expect(rerank(7, "now.value=#{1000 + 1_209_599}")).to include("a tier the owner set by hand is held")
    expect(tier_of).to eq(2)
  end

  it "holds the owner's hand rank against the real clock" do
    rank(2)
    expect(rerank(7)).to include("a tier the owner set by hand is held")
  end

  it "lets the product owner rank once the hold has passed" do
    rank(2, "now.value=1000")
    rerank(7, "now.value=#{1000 + 1_209_600}")
    expect(tier_of).to eq(7)
  end

  it "holds for as long as the owner said", :aggregate_failures do
    rank(2, "now.value=1000", "hold.value=60")
    expect(rerank(7, "now.value=1059")).to include("held")
    rerank(7, "now.value=1060")
    expect(tier_of).to eq(7)
  end
end
