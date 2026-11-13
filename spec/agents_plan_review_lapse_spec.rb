require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A plan review's time limit: a request stamps when it was asked and how long it may stay open, and
# a review lapses with a reason only once that limit has passed. Booted in Memory, one registry per
# run, with the clock given by hand.
RSpec.describe "the Agents plan review's time limit" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  it "stamps a request with when it was asked and a ten minute limit", :aggregate_failures do
    asked = request
    expect(asked.requested_at.value).to eq(1000)
    expect(asked.limit.value).to eq(600)
  end

  it "keeps the limit a request names" do
    expect(request(limit: { value: 60 }).limit.value).to eq(60)
  end

  it "refuses to lapse a review inside its limit, by name" do
    expect { lapse(request, at: 1599) }.to raise_error(Hecks::Runtime::GivenNotMet, /time limit has passed/)
  end

  it "lapses a review once its limit has passed, with the reason and the time", :aggregate_failures do
    lapsed = lapse(request, at: 1600)
    expect(lapsed.reason.value).to include("no verdict came")
    expect(lapsed.ended_at.value).to eq(1600)
  end
end
