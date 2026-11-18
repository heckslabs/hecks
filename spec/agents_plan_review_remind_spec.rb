require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A coder is marked as waiting only after its request returns, so a review refused at request time
# (the coder's worktree is not a directory yet) can end before the coder waits. The refusal was
# told to a coder that was not waiting: when the wait begins after the end, the verdict is kept to
# be sent again, with what to do. Booted in Memory with the clock given by hand.
RSpec.describe "the Agents plan review reminding a coder that waits after the end" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  def refused_at_request = unstart(request(asks: { value: 0 }))

  def remind(asked, at:) = asked.remind!(work: { value: "w1" }, now: { value: at })

  def verdict = Hecks::Agents::Verdict.find("r1")

  it "reminds a review refused at request when the coder's wait begins just after" do
    expect(remind(refused_at_request, at: 1030).reminded_at.value).to eq(1030)
  end

  it "keeps the refusal to be sent again with the worktree first", :aggregate_failures do
    remind(refused_at_request, at: 1030)
    expect(verdict.status).to eq("unresumed")
    expect(verdict.answer.value).to include("create your worktree first")
  end

  it "does not remind a review that holds a verdict, by name" do
    asked = request(asks: { value: 0 }).answer!(verdict: { value: "sound" })
    expect { remind(asked, at: 1030) }.to raise_error(Hecks::Runtime::GivenNotMet, /no verdict yet/)
  end

  it "does not remind a review still open, by name" do
    expect { remind(request(asks: { value: 0 }), at: 1030) }.to raise_error(Hecks::Runtime::GivenNotMet, /ended already/)
  end

  it "does not remind a review that ended long before the wait, by name" do
    expect { remind(refused_at_request, at: 5000) }.to raise_error(Hecks::Runtime::GivenNotMet, /ended just now/)
  end

  it "does not remind a review twice, by name" do
    reminded = remind(refused_at_request, at: 1030)
    expect { remind(reminded, at: 1031) }.to raise_error(Hecks::Runtime::GivenNotMet, /not reminded already/)
  end

  it "does not remind a review that was asked again, by name" do
    asked = request(asks: { value: 0 }).reask!(work: { value: "w1" }, hops: { value: 1 }, role: { value: "architect" },
                                               repo: { value: "/tmp" }, plan: { value: "a plan that is long enough" },
                                               now: { value: 1600 })
    expect { remind(asked, at: 1610) }.to raise_error(Hecks::Runtime::GivenNotMet, /not reminded already/)
  end
end
