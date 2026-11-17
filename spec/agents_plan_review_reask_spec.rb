require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A review whose first window passes with no verdict ends and the architect is asked once more, as
# a review of its own; only the second window lapses. A one-character plan is refused. Booted in
# Memory, one registry per run, with the clock given by hand.
RSpec.describe "the Agents plan review's second ask" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  def first_ask = request(asks: { value: 0 })

  def reask(asked, at:)
    asked.reask!(work: { value: "w1" }, hops: { value: 1 }, role: { value: "architect" }, repo: { value: "/tmp" },
                 plan: { value: "a plan that is long enough" }, now: { value: at })
  end

  it "refuses to ask again inside the first window, by name" do
    expect { reask(first_ask, at: 1599) }.to raise_error(Hecks::Runtime::GivenNotMet, /time limit has passed/)
  end

  it "ends the first review when the window has passed" do
    expect(reask(first_ask, at: 1600).ended_at.value).to eq(1600)
  end

  it "asks again once only, so a second ask is refused" do
    expect { reask(request, at: 1600) }.to raise_error(Hecks::Runtime::GivenNotMet, /asked again/)
  end

  it "refuses to lapse a review not yet asked again, by name" do
    expect { lapse(first_ask, at: 1600) }.to raise_error(Hecks::Runtime::GivenNotMet, /asked again already/)
  end

  it "lapses a review whose second window has passed" do
    expect(lapse(request, at: 1600).ended_at.value).to eq(1600)
  end

  it "refuses a plan that is no plan, by name" do
    expect { request(plan: { value: "x" }) }.to raise_error(/plan says what will be built/)
  end
end
