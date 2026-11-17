require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A plan review ends once: with a verdict, unstarted or lapsed. Each later end is refused by name,
# so the coder waiting on it is told one thing.
RSpec.describe "the Agents plan review ending once" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  def ended_already = raise_error(Hecks::Runtime::GivenNotMet, /not ended already/)

  it "refuses to lapse a review that holds a verdict, by name" do
    asked = request.answer!(verdict: { value: "sound" })
    expect { lapse(asked, at: 9000) }.to raise_error(Hecks::Runtime::GivenNotMet, /no verdict yet/)
  end

  it "refuses to lapse a review twice, by name" do
    lapsed = lapse(request, at: 1600)
    expect { lapse(lapsed, at: 9000) }.to ended_already
  end

  it "refuses to lapse an unstarted review, by name" do
    expect { lapse(unstart(request), at: 9000) }.to ended_already
  end

  it "refuses to unstart a lapsed review, by name" do
    expect { unstart(lapse(request, at: 1600)) }.to ended_already
  end

  it "refuses a verdict that comes after the lapse, by name" do
    lapsed = lapse(request, at: 1600)
    expect { lapsed.answer!(verdict: { value: "sound" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /did not end without a verdict/)
  end
end
