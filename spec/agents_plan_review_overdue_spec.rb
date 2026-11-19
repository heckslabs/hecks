require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A review whose first window passes with no verdict is overdue and asked again once; one whose
# second window passes lapses, and the coder waiting on it is told it is blocked and how to put
# that on the board's Stuck list. Booted in Memory, one registry per run, with the clock given by
# hand.
RSpec.describe "the Agents plan review's overdue verdict" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  it "names the verdict timeout in a Setting row that is the default limit" do
    expect(setting("verdict_timeout_seconds")[:value]).to eq(request(run: "d", asks: { value: 0 }).limit.value)
  end

  it "emits VerdictOverdue when the first window passes" do
    expect { reask(request(asks: { value: 0 }), at: 1600) }.to change { events_named("VerdictOverdue").size }.by(1)
  end

  it "emits ReviewLapsed beside ReviewUnstarted when the second window passes" do
    lapse(request, at: 1600)
    expect(%w[ReviewLapsed ReviewUnstarted].map { |name| events_named(name).size }).to eq([1, 1])
  end

  it "keeps a lapsed review from reminding its coder to build" do
    expect(lapse(request, at: 1600).reminded_at.value).to eq(1600)
  end

  it "puts the stuck item the blocked coder records on its finished turn" do
    finish_blocked_turn
    stuck = Hecks::Runtime::Value.materialize(events_named("TurnFinished").last.payload)[:stuck]
    items = stuck.map { |item| item.to_h.transform_keys(&:to_s) }
    expect(items).to contain_exactly(hash_including(PlanReviewLimitHelpers::OVERDUE_ITEM))
  end
end
