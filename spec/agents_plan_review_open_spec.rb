require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# The open plan reviews, which a sweep of the sessions reads to lapse the late ones: a review
# with no verdict and no end, asked for with a time.
RSpec.describe "the Agents open plan reviews" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  it "lists only a review with no verdict and no end" do
    request(run: "answered").answer!(verdict: { value: "sound" })
    lapse(request(run: "lapsed"), at: 1600)
    unstart(request(run: "unstarted"))
    request(run: "waiting")
    expect(open_runs).to eq(["waiting"])
  end

  it "does not list a review that carries no time" do
    review.record!(run: { value: "old" }, work: { value: "w1" }, verdict: { value: "sound" })
    expect(open_runs).to be_empty
  end
end
