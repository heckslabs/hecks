require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A plan review's verdict is answered once, so the coder waiting on its Work item is told once.
RSpec.describe "the Agents plan review verdict reaching its coder once" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  def answer(asked, word = "sound") = asked.answer!(verdict: { value: word })

  it "refuses a second verdict on a review that holds one, by name" do
    answered = answer(request)
    expect { answer(answered, "rethink") }.to raise_error(Hecks::Runtime::GivenNotMet, /no verdict yet/)
  end

  it "tells the coder of a review once when a second verdict is refused", :aggregate_failures do
    answered = answer(request)
    expect { answer(answered) }.to raise_error(Hecks::Runtime::GivenNotMet)
    expect(events_named("PlanReviewed").size).to eq(1)
  end

  it "refuses a verdict after one that checked nothing, so a new review asks again" do
    unverified = answer(request, "unverified")
    expect { answer(unverified, "sound") }.to raise_error(Hecks::Runtime::GivenNotMet, /no verdict yet/)
  end

  it "refuses a judged verdict for the same judge run twice" do
    judge = -> { Hecks::Agents::Verdict.judge!(run: { value: "r1" }, work: { value: "w1" }, role: { value: "architect" }, answer: { value: "sound" }) }
    judge.call
    expect { judge.call }.to raise_error(Hecks::Runtime::AlreadyExists)
  end
end
